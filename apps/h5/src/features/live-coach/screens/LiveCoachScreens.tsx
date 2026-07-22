import {
  ArrowRight,
  Camera,
  Check,
  CircleNotch,
  DeviceMobileCamera,
  Images,
  Microphone,
  MicrophoneSlash,
  Repeat,
  ShieldCheck,
  Warning,
} from "@phosphor-icons/react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import {
  SoloShotApiError,
  soloShotApi,
  type SoloShotSession,
} from "../../../apiClient";
import { analytics } from "../../../analytics";
import { PageHeader } from "../../../components/AppChrome";
import { findTestImageCaseByReferenceId } from "../../../dataset";
import type { PreparedImage } from "../../../media/processing";
import { sha256 } from "../../../media/processing";
import { CameraController, checkCameraSupport } from "../camera/cameraController";
import { captureVideoFrame, sharpnessScore } from "../camera/frameCapture";
import {
  rankCandidates,
  scoreCandidate,
  type CaptureCandidate,
} from "../domain/candidateScoring";
import type {
  AlignmentDecision,
  CoachTarget,
  CompletionMode,
} from "../domain/alignmentModels";
import { instructionCopy } from "../feedback/instructionCopy";
import { SpeechController } from "../feedback/speechController";
import {
  createCaptureDraft,
  deleteCaptureDraft,
  loadCaptureDraft,
  rotateUploadAttempt,
  saveCaptureDraft,
  type CaptureDraft,
} from "../persistence/captureDraftStore";
import { CoachRuntime, type CoachRuntimeStats } from "../runtime/coachRuntime";
import {
  cachePreparedPoseRuntime,
  loadReferenceSilhouette,
  takePreparedPoseRuntime,
} from "../runtime/preparedPoseCache";

type Round = 1 | 2;
type LivePhase =
  | "restoring"
  | "starting"
  | "coaching"
  | "countdown"
  | "capturing"
  | "candidates"
  | "uploading"
  | "error";

const LIVE_PREFERENCE_PREFIX = "soloshot:live-coach:";

async function loadPoseRuntime() {
  const module = await import("../pose/poseLandmarker");
  return module.createPoseRuntime();
}

async function loadReferenceImage(session: SoloShotSession): Promise<HTMLImageElement> {
  const reference = session.reference_asset;
  if (reference === null || reference === undefined) throw new Error("REFERENCE_IMAGE_UNAVAILABLE");
  const preset = findTestImageCaseByReferenceId(reference.reference_id);
  let source: string;
  if (reference.source_type === "preset" && preset !== null) {
    source = preset.publicAssets.detail;
  } else if (reference.media_asset_id !== null && reference.media_asset_id !== undefined) {
    const access = await soloShotApi.getMediaAccess(session.session_id, reference.media_asset_id);
    source = access.data.download_url;
  } else {
    throw new Error("REFERENCE_IMAGE_UNAVAILABLE");
  }
  const image = new Image();
  image.crossOrigin = "anonymous";
  image.decoding = "async";
  await new Promise<void>((resolve, reject) => {
    image.onload = () => resolve();
    image.onerror = () => reject(new Error("REFERENCE_IMAGE_LOAD_FAILED"));
    image.src = source;
  });
  return image;
}

async function preparePoseRuntime(session: SoloShotSession) {
  const module = await import("../pose/poseLandmarker");
  const selected = session.reference_asset?.selected_box;
  if (selected === undefined || selected === null) {
    return {
      runtime: await module.createPoseRuntime(),
      reference: { status: "extraction_failed" as const, contour: null },
    };
  }
  try {
    const image = await loadReferenceImage(session);
    return await module.createPreparedPoseRuntime(image, selected);
  } catch {
    return {
      runtime: await module.createPoseRuntime(),
      reference: { status: "extraction_failed" as const, contour: null },
    };
  }
}

export function setLiveCoachPreference(sessionId: string, enabled: boolean): void {
  if (enabled) window.sessionStorage.setItem(`${LIVE_PREFERENCE_PREFIX}${sessionId}`, "1");
  else window.sessionStorage.removeItem(`${LIVE_PREFERENCE_PREFIX}${sessionId}`);
}

export function prefersLiveCoach(sessionId: string): boolean {
  return window.sessionStorage.getItem(`${LIVE_PREFERENCE_PREFIX}${sessionId}`) === "1";
}

function useLiveSession() {
  const params = useParams<{ id: string; round: string }>();
  const sessionId = params.id ?? "";
  const round: Round = params.round === "2" ? 2 : 1;
  const query = useQuery({
    queryKey: ["session", sessionId],
    queryFn: () => soloShotApi.getSession(sessionId),
    enabled: sessionId.startsWith("ss_"),
  });
  return { sessionId, round, query };
}

function targetFor(session: SoloShotSession): CoachTarget | null {
  const layout = session.shot_plan?.target_layout;
  if (layout === undefined || layout === null) return null;
  const left = Math.max(0, Math.min(1, layout.center_x - layout.width / 2));
  const top = Math.max(0, Math.min(1, layout.center_y - layout.height / 2));
  const right = Math.max(left, Math.min(1, layout.center_x + layout.width / 2));
  const bottom = Math.max(top, Math.min(1, layout.center_y + layout.height / 2));
  return {
    rect: {
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    },
    bodyDirection: layout.body_direction,
    poseTemplate: layout.pose_template,
  };
}

function userMessage(error: unknown): string {
  if (error instanceof DOMException && error.name === "NotAllowedError") {
    return "相机权限没有开启。可以在 Safari 网站设置中允许相机，或直接拍照上传。";
  }
  if (error instanceof SoloShotApiError) return error.message;
  if (error instanceof Error && error.message === "INSECURE_CONTEXT") {
    return "浏览器实时陪拍需要 HTTPS 安全连接。";
  }
  return "当前浏览器没有完成实时陪拍初始化，但你的 ShotPlan 仍然保留。";
}

function errorCode(error: unknown): string {
  if (error instanceof SoloShotApiError) return error.code;
  if (error instanceof DOMException && error.name === "NotAllowedError") return "CAMERA_PERMISSION_DENIED";
  return error instanceof Error ? error.message.slice(0, 64) : "LIVE_COACH_UNKNOWN_ERROR";
}

export function DeviceCheckScreen() {
  const navigate = useNavigate();
  const { sessionId, round, query } = useLiveSession();
  const support = checkCameraSupport();
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [loadMs, setLoadMs] = useState<number | null>(null);

  if (query.isLoading) {
    return <LiveLoading label="正在检查浏览器能力…" />;
  }
  const session = query.data?.data;
  if (query.error !== null || session === undefined || targetFor(session) === null) {
    return (
      <LiveFallback
        message="ShotPlan 尚未准备好，暂时不能开启浏览器陪拍。"
        onFallback={() => navigate(`/session/${sessionId}/capture/${round}`)}
      />
    );
  }
  if (session.state === "handoff_ready") {
    return (
      <LiveFallback
        message="任务正在接力给 iPhone。请先取消任务码，再使用浏览器陪拍。"
        onFallback={() => navigate(`/session/${sessionId}/handoff`)}
        action="查看 iPhone 接力"
      />
    );
  }
  const readySession = session;

  async function prepare(): Promise<void> {
    if (!support.supported) {
      setError(new Error("INSECURE_CONTEXT"));
      return;
    }
    setChecking(true);
    setError(null);
    const started = performance.now();
    try {
      const prepared = await preparePoseRuntime(readySession);
      cachePreparedPoseRuntime(sessionId, prepared);
      setLoadMs(performance.now() - started);
      setLiveCoachPreference(sessionId, true);
      analytics.track(
        "h5_capture_start",
        {
          source: "live_camera",
          round_index: round,
          latency_ms: Math.round(performance.now() - started),
          reference_silhouette_status: prepared.reference.status,
        },
        sessionId,
      );
      void analytics.flush(sessionId);
      navigate(`/session/${sessionId}/live/${round}`);
    } catch (caught) {
      setError(caught);
      analytics.track(
        "h5_capture_start",
        { source: "live_camera", round_index: round, status: "failed", error_code: errorCode(caught) },
        sessionId,
      );
      void analytics.flush(sessionId);
    } finally {
      setChecking(false);
    }
  }

  return (
    <section className="page live-check-page">
      <PageHeader title="浏览器现场陪拍" backTo={`/session/${sessionId}/plan`} />
      <div className="live-check-hero">
        <DeviceMobileCamera size={34} weight="fill" aria-hidden="true" />
        <h1>免安装，也能跟着轮廓完成这一拍</h1>
        <p>iPhone App 仍是最佳体验；这里使用设备本地 MediaPipe 完成核心陪拍旅程。</p>
      </div>
      <div className="device-check-list">
        <CheckRow ok={support.secureContext} label="HTTPS 安全连接" />
        <CheckRow ok={support.mediaDevices} label="浏览器相机能力" />
        <CheckRow ok label="本地姿态与人形检测，不上传关键点、Mask 和预览帧" />
        <CheckRow ok label="拍摄失败时可随时切换为照片上传" />
      </div>
      <div className="privacy-card">
        <ShieldCheck size={25} weight="fill" aria-hidden="true" />
        <span>
          <strong>画面先留在你的设备里</strong>
          <small>只有你最终确认的一张 JPEG 会被上传用于评价。</small>
        </span>
      </div>
      {session.shot_plan?.capture_mode === "short_video" ? (
        <p className="live-model-status">此 ShotPlan 在浏览器中使用三张照片降级；原生短视频仍请使用 iPhone App。</p>
      ) : null}
      {loadMs !== null ? <p className="live-model-status">模型已准备好 · {Math.round(loadMs)} ms</p> : null}
      {error !== null ? <p className="live-error" role="alert">{userMessage(error)}</p> : null}
      <button type="button" className="primary-button" disabled={checking} onClick={() => void prepare()}>
        {checking ? <CircleNotch className="spin" size={20} /> : <Camera size={20} />}
        {checking ? "正在下载并预热模型…" : "开启相机并开始陪拍"}
      </button>
      <button
        type="button"
        className="secondary-button"
        onClick={() => {
          setLiveCoachPreference(sessionId, false);
          navigate(`/session/${sessionId}/capture/${round}`);
        }}
      >
        直接拍照或上传
      </button>
    </section>
  );
}

function CheckRow({ ok, label }: { ok: boolean; label: string }) {
  return (
    <div className={ok ? "check-ok" : "check-fail"}>
      {ok ? <Check size={19} weight="bold" /> : <Warning size={19} weight="fill" />}
      <span>{label}</span>
    </div>
  );
}

function LiveLoading({ label }: { label: string }) {
  return (
    <div className="center-state" role="status">
      <CircleNotch className="spin" size={34} />
      <strong>{label}</strong>
    </div>
  );
}

function LiveFallback({
  message,
  onFallback,
  action = "改用拍照或上传",
}: {
  message: string;
  onFallback: () => void;
  action?: string;
}) {
  return (
    <section className="page">
      <div className="center-state error-state" role="alert">
        <Warning size={34} weight="fill" />
        <strong>实时陪拍暂时不可用</strong>
        <small>{message}</small>
        <button type="button" className="primary-button" onClick={onFallback}>{action}</button>
      </div>
    </section>
  );
}

export function LiveCoachScreen() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { sessionId, round, query } = useLiveSession();
  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const cameraRef = useRef<CameraController | null>(null);
  const runtimeRef = useRef<CoachRuntime | null>(null);
  const candidatesRef = useRef<CaptureCandidate[]>([]);
  const speechRef = useRef(new SpeechController(true));
  const phaseRef = useRef<LivePhase>("restoring");
  const latestDecisionRef = useRef<AlignmentDecision | null>(null);
  const countdownTimersRef = useRef<number[]>([]);
  const manualLockRef = useRef(false);
  const [phase, setPhaseState] = useState<LivePhase>("restoring");
  const [decision, setDecision] = useState<AlignmentDecision | null>(null);
  const [stats, setStats] = useState<CoachRuntimeStats | null>(null);
  const [countdown, setCountdown] = useState(3);
  const [candidates, setCandidates] = useState<CaptureCandidate[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [draft, setDraft] = useState<CaptureDraft | null>(null);
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<unknown>(null);
  const [speechEnabled, setSpeechEnabled] = useState(true);
  const [manualConfirming, setManualConfirming] = useState(false);

  const setPhase = useCallback((next: LivePhase) => {
    phaseRef.current = next;
    setPhaseState(next);
  }, []);

  const stopCamera = useCallback(() => {
    runtimeRef.current?.stop();
    runtimeRef.current = null;
    cameraRef.current?.stop();
    cameraRef.current = null;
    speechRef.current.stop();
  }, []);

  const captureBurst = useCallback(async () => {
    const video = videoRef.current;
    if (video === null) return;
    setPhase("capturing");
    const captured: CaptureCandidate[] = [];
    try {
      for (let index = 0; index < 3; index += 1) {
        const capturedAt = performance.now();
        const image = await captureVideoFrame(video);
        const sharpness = await sharpnessScore(image.blob);
        captured.push(
          scoreCandidate(
            `frame_h5_${round}_${Date.now()}_${index}`,
            image,
            capturedAt,
            runtimeRef.current?.getDecision() ?? latestDecisionRef.current,
            sharpness,
          ),
        );
        if (index < 2) await new Promise((resolve) => window.setTimeout(resolve, 220));
      }
      stopCamera();
      const ranked = rankCandidates(captured);
      candidatesRef.current = ranked;
      setCandidates(ranked);
      setSelectedId(ranked[0]?.id ?? null);
      setPhase("candidates");
    } catch (caught) {
      captured.forEach((candidate) => URL.revokeObjectURL(candidate.image.previewUrl));
      setError(caught);
      setPhase("error");
      stopCamera();
    }
  }, [round, setPhase, stopCamera]);

  const beginCountdown = useCallback(() => {
    if (phaseRef.current !== "coaching") return;
    setPhase("countdown");
    setCountdown(3);
    countdownTimersRef.current.forEach((timer) => window.clearTimeout(timer));
    countdownTimersRef.current = [1, 2, 3].map((step) =>
      window.setTimeout(() => {
        const current = latestDecisionRef.current;
        if (!manualLockRef.current && current?.countdownStillValid !== true) {
          countdownTimersRef.current.forEach((timer) => window.clearTimeout(timer));
          countdownTimersRef.current = [];
          setPhase("coaching");
          setCountdown(3);
          return;
        }
        if (step < 3) setCountdown(3 - step);
        else void captureBurst();
      }, step * 1_000),
    );
  }, [captureBurst, setPhase]);

  useEffect(() => {
    if (query.data === undefined) return;
    let cancelled = false;
    void loadCaptureDraft(sessionId, round)
      .then((restored) => {
        if (cancelled) return;
        if (restored !== null) {
          setDraft(restored);
          const image: PreparedImage = {
            blob: restored.blob,
            previewUrl: URL.createObjectURL(restored.blob),
            width: restored.width,
            height: restored.height,
            mediaType: "image",
          };
          setCandidates([
            {
              id: restored.candidateId,
              capturedAt: restored.createdAt,
              image,
              localScore: restored.localScore,
              reasons: restored.reasons,
              metrics: {
                completeFraming: 0,
                targetPositionMatch: 0,
                personScaleMatch: 0,
                sharpness: 0,
                supportedPoseMatch: null,
                personCount: 1,
                headAndFeetVisible: true,
                averageConfidence: 0,
              },
            },
          ]);
          candidatesRef.current = [
            {
              id: restored.candidateId,
              capturedAt: restored.createdAt,
              image,
              localScore: restored.localScore,
              reasons: restored.reasons,
              metrics: {
                completeFraming: 0,
                targetPositionMatch: 0,
                personScaleMatch: 0,
                sharpness: 0,
                supportedPoseMatch: null,
                personCount: 1,
                headAndFeetVisible: true,
                averageConfidence: 0,
              },
            },
          ];
          setSelectedId(restored.candidateId);
          setPhase("candidates");
        } else {
          setPhase("starting");
        }
      })
      .catch(() => setPhase("starting"));
    return () => {
      cancelled = true;
    };
  }, [query.data, round, sessionId, setPhase]);

  useEffect(() => {
    const session = query.data?.data;
    const target = session === undefined ? null : targetFor(session);
    if (phase !== "starting" || target === null) return;
    const video = videoRef.current;
    const canvas = canvasRef.current;
    if (video === null || canvas === null) return;
    let cancelled = false;
    const camera = new CameraController();
    cameraRef.current = camera;
    void (async () => {
      try {
        if (!checkCameraSupport().supported) throw new Error("INSECURE_CONTEXT");
        await camera.start(video);
        const pose = takePreparedPoseRuntime(sessionId) ?? await loadPoseRuntime();
        if (cancelled) {
          pose.close();
          return;
        }
        const reference = loadReferenceSilhouette(sessionId);
        const runtime = new CoachRuntime(video, canvas, pose, target, reference.contour, (nextDecision, nextStats) => {
          latestDecisionRef.current = nextDecision;
          setDecision(nextDecision);
          setStats(nextStats);
          speechRef.current.speak(nextDecision.instructionCode);
          if (phaseRef.current === "countdown" && !manualLockRef.current && !nextDecision.countdownStillValid) {
            countdownTimersRef.current.forEach((timer) => window.clearTimeout(timer));
            countdownTimersRef.current = [];
            setCountdown(3);
            setPhase("coaching");
          } else if (nextDecision.readyToCapture && phaseRef.current === "coaching") {
            beginCountdown();
          }
        });
        runtimeRef.current = runtime;
        runtime.start();
        setPhase("coaching");
      } catch (caught) {
        if (!cancelled) {
          setError(caught);
          setPhase("error");
          camera.stop();
          analytics.track(
            "h5_capture_start",
            { source: "live_camera", round_index: round, status: "failed", error_code: errorCode(caught) },
            sessionId,
          );
          void analytics.flush(sessionId);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [beginCountdown, phase, query.data, setPhase]);

  useEffect(() => {
    return () => {
      countdownTimersRef.current.forEach((timer) => window.clearTimeout(timer));
      stopCamera();
      candidatesRef.current.forEach((candidate) => URL.revokeObjectURL(candidate.image.previewUrl));
    };
    // Object URLs are released when this screen unmounts; candidate changes are intentionally ignored.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stopCamera]);

  const uploadDraft = useCallback(
    async (startingDraft: CaptureDraft, session: SoloShotSession) => {
      setPhase("uploading");
      setError(null);
      setProgress(2);
      let work = startingDraft;
      try {
        const fixture =
          session.mode === "original_replication" && session.reference_asset?.source_type === "preset";
        if (work.networkStep === "consent") {
          await soloShotApi.recordCaptureConsent(sessionId, !fixture, `h5-live-consent-${sessionId}-${round}`);
          work = { ...work, networkStep: "upload" };
          await saveCaptureDraft(work);
        }
        setProgress(10);
        if (work.mediaAssetId === null) {
          const digest = await sha256(work.blob);
          const ticket = await soloShotApi.createMediaUpload(
            sessionId,
            "capture",
            work.blob,
            digest,
            undefined,
            work.uploadCreateKey,
          );
          setProgress(28);
          const response = await fetch(ticket.data.upload_url, {
            method: "PUT",
            headers: ticket.data.upload_headers,
            body: work.blob,
          });
          if (!response.ok) throw new SoloShotApiError("媒体上传失败，请重试。", "CAPTURE_UPLOAD_FAILED", true);
          setProgress(64);
          const completed = await soloShotApi.completeMediaUpload(
            sessionId,
            ticket.data.asset.media_asset_id,
            undefined,
            work.uploadCompleteKey,
          );
          work = { ...work, mediaAssetId: completed.data.media_asset_id, networkStep: "capture" };
          await saveCaptureDraft(work);
        }
        setProgress(76);
        if (work.captureId === null) {
          const mediaAssetId = work.mediaAssetId;
          if (mediaAssetId === null) throw new Error("CAPTURE_MEDIA_MISSING");
          const capture = await soloShotApi.createCapture(sessionId, mediaAssetId, round, {
            captureMethod: session.shot_plan?.capture_mode === "short_video" ? "photo_fallback" : "photo",
            frameSelection: {
              frameId: work.candidateId,
              timestampMs: null,
              selectionSource:
                work.selectionSource,
            },
            stableIdempotencyKey: work.captureKey,
          });
          work = { ...work, captureId: capture.data.capture_id, networkStep: "evaluate" };
          await saveCaptureDraft(work);
        }
        setProgress(86);
        const captureId = work.captureId;
        if (captureId === null) throw new Error("CAPTURE_ID_MISSING");
        const evaluation = await soloShotApi.createEvaluation(sessionId, captureId, work.evaluationKey);
        setProgress(100);
        await deleteCaptureDraft(sessionId, round);
        setDraft(null);
        analytics.track(
          "result_evaluated",
          { round_index: round, execution_mode: evaluation.executionMode ?? (fixture ? "fixture" : "live") },
          sessionId,
        );
        await analytics.flush(sessionId);
        await queryClient.invalidateQueries({ queryKey: ["session", sessionId] });
        candidatesRef.current.forEach((candidate) => URL.revokeObjectURL(candidate.image.previewUrl));
        candidatesRef.current = [];
        navigate(`/session/${sessionId}/evaluation/${round}`);
      } catch (caught) {
        if (work.mediaAssetId === null && work.networkStep === "upload") {
          work = rotateUploadAttempt(work);
          await saveCaptureDraft(work).catch(() => undefined);
        }
        setDraft(work);
        setError(caught);
        setPhase("candidates");
      }
    },
    [candidates, navigate, queryClient, round, sessionId, setPhase],
  );

  const selectAndUpload = useCallback(
    async (session: SoloShotSession) => {
      const selected = candidates.find((candidate) => candidate.id === selectedId);
      if (selected === undefined) return;
      const selectionSource =
        candidates[0]?.id === selected.id ? "local_recommended" : "user_selected";
      candidates
        .filter((candidate) => candidate.id !== selected.id)
        .forEach((candidate) => URL.revokeObjectURL(candidate.image.previewUrl));
      candidatesRef.current = [selected];
      setCandidates([selected]);
      const nextDraft =
        draft ??
        createCaptureDraft({
          sessionId,
          round,
          blob: selected.image.blob,
          width: selected.image.width,
          height: selected.image.height,
          candidateId: selected.id,
          selectionSource,
          localScore: selected.localScore,
          reasons: selected.reasons,
        });
      try {
        await saveCaptureDraft(nextDraft);
      } catch {
        // Continue in the current foreground session; upload errors remain recoverable while this page is open.
      }
      setDraft(nextDraft);
      await uploadDraft(nextDraft, session);
    },
    [candidates, draft, round, selectedId, sessionId, uploadDraft],
  );

  if (query.isLoading || phase === "restoring") return <LiveLoading label="正在恢复现场陪拍…" />;
  const session = query.data?.data;
  if (query.error !== null || session === undefined || targetFor(session) === null) {
    return <LiveFallback message="当前 Session 无法进入实时陪拍。" onFallback={() => navigate(`/session/${sessionId}/capture/${round}`)} />;
  }

  if (phase === "candidates" || phase === "uploading") {
    return (
      <section className="page live-candidate-page">
        <PageHeader title={round === 1 ? "选出第一次成片" : "选出调整后的成片"} backTo={`/session/${sessionId}/plan`} />
        <div className="candidate-heading">
          <Images size={28} weight="fill" />
          <span><strong>照片只在本地比较</strong><small>确认后只上传你选择的一张 JPEG。</small></span>
        </div>
        <div className="candidate-grid">
          {candidates.map((candidate, index) => (
            <button
              type="button"
              key={candidate.id}
              className={selectedId === candidate.id ? "candidate-card selected" : "candidate-card"}
              onClick={() => setSelectedId(candidate.id)}
              disabled={phase === "uploading"}
            >
              <img src={candidate.image.previewUrl} alt={`本地候选 ${index + 1}`} />
              <span>
                <strong>{index === 0 ? "本地推荐" : `候选 ${index + 1}`}</strong>
                <small>{candidate.reasons.join(" · ")}</small>
              </span>
              {selectedId === candidate.id ? <Check size={20} weight="bold" /> : null}
            </button>
          ))}
        </div>
        {phase === "uploading" ? (
          <div className="live-upload-progress" role="status">
            <strong>正在安全上传并评价… {progress}%</strong>
            <div><span style={{ width: `${progress}%` }} /></div>
          </div>
        ) : null}
        {error !== null ? <p className="live-error" role="alert">{userMessage(error)} 已选照片仍保留在本机，可以重试。</p> : null}
        <button
          type="button"
          className="primary-button"
          disabled={selectedId === null || phase === "uploading"}
          onClick={() => void selectAndUpload(session)}
        >
          {error === null ? "确认这一张并开始评价" : "继续上传和评价"} <ArrowRight size={20} />
        </button>
      </section>
    );
  }

  if (phase === "error") {
    return (
      <LiveFallback
        message={userMessage(error)}
        onFallback={() => {
          setLiveCoachPreference(sessionId, false);
          navigate(`/session/${sessionId}/capture/${round}`);
        }}
      />
    );
  }

  const completionLabel: Record<CompletionMode, string> = {
    verified: "姿态与构图已验证",
    composition_only: "构图已验证，动作使用简化判断",
    manual: "手动确认，未经姿态验证",
  };
  const referenceSilhouette = loadReferenceSilhouette(sessionId);
  return (
    <section className="live-camera-page">
      <video ref={videoRef} className="live-video" autoPlay playsInline muted aria-label="后置相机预览" />
      <canvas ref={canvasRef} className="live-overlay" aria-hidden="true" />
      <div className="live-camera-topbar">
        <button type="button" onClick={() => { stopCamera(); navigate(`/session/${sessionId}/plan`); }}>退出</button>
        <span>{round === 1 ? "第一次拍摄" : "第二次，只改一个问题"}</span>
        <button
          type="button"
          aria-label={speechEnabled ? "关闭语音" : "开启语音"}
          onClick={() => {
            const next = !speechEnabled;
            setSpeechEnabled(next);
            speechRef.current.setEnabled(next);
          }}
        >
          {speechEnabled ? <Microphone size={21} /> : <MicrophoneSlash size={21} />}
        </button>
      </div>
      <div className="live-instruction" role="status" aria-live="polite">
        <strong>{decision === null ? "正在寻找人物…" : instructionCopy[decision.instructionCode]}</strong>
        <small>
          {decision?.completionMode === null || decision?.completionMode === undefined
            ? decision?.silhouetteScore === null || decision?.silhouetteScore === undefined
              ? referenceSilhouette.status === "ready"
                ? "正在识别人形…"
                : "构图辅助已启用"
              : `轮廓匹配度 ${Math.round(decision.silhouetteScore * 100)}% · 建议 80%`
            : completionLabel[decision.completionMode]}
        </small>
      </div>
      {phase === "countdown" ? <div className="live-countdown" aria-live="assertive">{countdown}</div> : null}
      {phase === "capturing" ? <div className="live-countdown capture-flash">拍摄中</div> : null}
      <div className="live-camera-controls">
        {stats !== null && stats.inferenceP95 > 350 ? <small>设备性能有限，已自动降低检测频率</small> : null}
        {referenceSilhouette.status !== "ready" ? <small>参考轮廓不可用，已改用构图辅助</small> : null}
        {decision?.manualReadyAvailable === true && phase === "coaching" ? (
          <button
            type="button"
            className="manual-ready-button"
            onClick={() => {
              if (!manualConfirming) {
                setManualConfirming(true);
                return;
              }
              manualLockRef.current = true;
              runtimeRef.current?.manualCompletion();
              beginCountdown();
            }}
          >
            {manualConfirming ? "再次确认：我已安全就位" : "检测不到？手动确认已就位"}
          </button>
        ) : null}
        <button
          type="button"
          className="live-upload-fallback"
          onClick={() => {
            stopCamera();
            setLiveCoachPreference(sessionId, false);
            navigate(`/session/${sessionId}/capture/${round}`);
          }}
        >
          改用拍照或上传
        </button>
      </div>
    </section>
  );
}
