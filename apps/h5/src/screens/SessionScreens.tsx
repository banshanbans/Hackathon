import {
  ArrowRight,
  Camera,
  Check,
  CheckCircle,
  CircleNotch,
  DeviceMobile,
  Footprints,
  Mountains,
  Repeat,
  Sparkle,
  Warning,
} from "@phosphor-icons/react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import {
  SoloShotApiError,
  soloShotApi,
  type Capture,
  type ExecutionMode,
  type ReferenceAnalysis,
  type ResultEvaluation,
  type SoloShotSession,
} from "../apiClient";
import { analytics } from "../analytics";
import { PageHeader, StateNotice } from "../components/AppChrome";
import {
  IOSExperienceSheet,
  type IOSExperienceState,
} from "../components/IOSExperienceSheet";
import { MediaPicker, UploadProgress } from "../components/MediaPicker";
import { findTestImageCase } from "../dataset";
import {
  type SceneOperationKeys,
  type SceneStage,
  useFlow,
} from "../flow/FlowProvider";
import {
  createHandoffDraft,
  loadHandoffDraft,
  saveHandoffDraft,
} from "../handoff/storage";
import {
  cameraAngleLabel,
  cameraHeightLabel,
  captureModeLabel,
  lensLabel,
  poseLabel,
  productErrorCopy,
  roundLabel,
} from "../productCopy";
import { buildResultComparisonItems, type ResultComparisonItem } from "../resultComparison";
import {
  prefersLiveCoach,
  setLiveCoachPreference,
} from "../features/live-coach/screens/LiveCoachScreens";

function useSession() {
  const params = useParams<{ id: string }>();
  const sessionId = params.id ?? "";
  const query = useQuery({
    queryKey: ["session", sessionId],
    queryFn: () => soloShotApi.getSession(sessionId),
    enabled: sessionId.startsWith("ss_"),
    refetchOnWindowFocus: true,
  });
  return { sessionId, query };
}

function Loading({ label = "正在找回你的 ShotPlan…" }: { label?: string }) {
  return (
    <div className="center-state" role="status">
      <CircleNotch className="spin" size={34} aria-hidden="true" />
      <strong>{label}</strong>
      <small>上次进度已为你保留</small>
    </div>
  );
}

function AsyncError({ error, onRetry }: { error: unknown; onRetry: () => void }) {
  const apiError =
    error instanceof SoloShotApiError
      ? error
      : new SoloShotApiError("当前步骤没有完成。", "REQUEST_FAILED", true);
  const copy = productErrorCopy(apiError.code);
  return (
    <div className="center-state error-state" role="alert">
      <Warning size={34} weight="fill" aria-hidden="true" />
      <strong>{copy.title}</strong>
      <small>{copy.detail}</small>
      {apiError.recoverable ? (
        <button type="button" className="secondary-button" onClick={onRetry}>
          <Repeat size={18} aria-hidden="true" /> 再试一次
        </button>
      ) : null}
    </div>
  );
}

function modeForSession(session: SoloShotSession, current: string | null): ExecutionMode {
  const persisted = session.evaluations.at(-1)?.execution_mode;
  if (persisted === "fixture" || persisted === "live" || persisted === "fallback") {
    return persisted;
  }
  if (
    session.mode === "original_replication" &&
    session.reference_asset?.source_type === "preset"
  ) {
    return current === "mock" ? "mock" : "fixture";
  }
  if (current === "fallback") {
    return "fallback";
  }
  return "live";
}

export function AnalysisScreen() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { state, dispatch } = useFlow();
  const { sessionId, query } = useSession();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  if (query.isLoading) {
    return <Loading label="正在读懂你的灵感…" />;
  }
  if (query.error !== null || query.data === undefined) {
    return <AsyncError error={query.error} onRetry={() => void query.refetch()} />;
  }
  const session = query.data.data;
  const mode = modeForSession(session, state.executionMode);

  async function createPlan(): Promise<void> {
    setBusy(true);
    setError(null);
    try {
      const run = await soloShotApi.createAgentRun(sessionId, session.mode);
      dispatch({ type: "patch", value: { executionMode: run.executionMode ?? mode } });
      await queryClient.invalidateQueries({ queryKey: ["session", sessionId] });
      analytics.track(
        "shot_plan_view",
        { mode: session.mode, execution_mode: run.executionMode ?? mode },
        sessionId,
      );
      await analytics.flush(sessionId);
      navigate(`/session/${sessionId}/plan`);
    } catch (caught) {
      setError(caught);
      dispatch({ type: "patch", value: { executionMode: "error" } });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="page analysis-page">
      <PageHeader title="你的灵感，已经读懂" backTo="/constraints" />
      <div className="analysis-success">
        <span>
          <Check size={28} weight="bold" aria-hidden="true" />
        </span>
        <p>人物、构图与氛围已经整理成一份可执行的拍摄意图。</p>
      </div>
      <StateNotice mode={mode}>
        {mode === "fixture"
          ? "接下来将生成一份精选样例 ShotPlan。"
          : "你的灵感已安全保存，可以继续创作。"}
      </StateNotice>

      {error !== null ? <AsyncError error={error} onRetry={() => void createPlan()} /> : null}
      <button
        type="button"
        className="primary-button"
        disabled={busy}
        onClick={() => {
          if (session.mode === "scene_adaptation") {
            navigate(`/session/${sessionId}/scene`);
          } else {
            void createPlan();
          }
        }}
      >
        {busy
          ? "AI 摄影导演正在设计…"
          : session.mode === "scene_adaptation"
            ? "看看我眼前的现场"
            : "生成我的 ShotPlan"}
        <ArrowRight size={20} aria-hidden="true" />
      </button>
    </section>
  );
}

export function SceneScreen() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { state, dispatch } = useFlow();
  const { sessionId, query } = useSession();
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<unknown>(null);
  const [layout, setLayout] = useState<ReferenceAnalysis["target_layout"] | null>(null);
  const controllerRef = useRef<AbortController | null>(null);
  const runningRef = useRef(false);

  useEffect(() => () => controllerRef.current?.abort(), []);

  useEffect(() => {
    const session = query.data?.data;
    if (
      session === undefined ||
      session.mode !== "scene_adaptation" ||
      state.sceneMedia !== null ||
      runningRef.current ||
      (state.sceneStage !== "recognizing" && state.sceneStage !== "generating")
    ) {
      return;
    }
    if (session.shot_plan !== null) {
      navigate(`/session/${sessionId}/plan`, { replace: true });
      return;
    }
    const assetId = session.scene_asset_id ?? state.sceneAssetId;
    if (assetId === null) {
      return;
    }
    const keys = state.sceneOperationKeys ?? createSceneOperationKeys();
    void runSceneFlow(session, null, assetId, keys);
  }, [
    query.data,
    sessionId,
    state.sceneAssetId,
    state.sceneMedia,
    state.sceneOperationKeys,
    state.sceneStage,
  ]);

  if (query.isLoading) {
    return <Loading />;
  }
  if (query.error !== null || query.data === undefined) {
    return <AsyncError error={query.error} onRetry={() => void query.refetch()} />;
  }
  const session = query.data.data;

  async function runSceneFlow(
    currentSession: SoloShotSession,
    media: typeof state.sceneMedia,
    existingAssetId: string | null,
    keys: SceneOperationKeys,
  ): Promise<void> {
    if ((media === null && existingAssetId === null) || currentSession.reference_asset === null) {
      setError(
        new SoloShotApiError(
          "刷新后尚未提交的本地现场图无法恢复，请重新选择。",
          "MEDIA_NOT_READY",
          true,
        ),
      );
      return;
    }
    const abortController = new AbortController();
    controllerRef.current?.abort();
    controllerRef.current = abortController;
    const isCurrentOperation = () => controllerRef.current === abortController;
    runningRef.current = true;
    setError(null);
    let activeStage: "uploading" | "recognizing" | "generating" =
      existingAssetId === null ? "uploading" : "recognizing";
    let stageStartedAt = performance.now();
    try {
      let sceneAssetId = existingAssetId;
      if (sceneAssetId === null) {
        if (media === null) {
          throw new SoloShotApiError("请重新选择现场图。", "MEDIA_NOT_READY", true);
        }
        dispatch({ type: "patch", value: { sceneStage: "uploading", sceneOperationKeys: keys } });
        const uploadStarted = performance.now();
        const uploaded = await soloShotApi.uploadMedia(sessionId, "scene", media.blob, {
          signal: abortController.signal,
          onProgress: setProgress,
          createIdempotencyKey: keys.uploadCreate,
          completeIdempotencyKey: keys.uploadComplete,
        });
        sceneAssetId = uploaded.media_asset_id;
        dispatch({ type: "patch", value: { sceneAssetId, sceneStage: "recognizing" } });
        analytics.track(
          "reference_upload",
          { source: "scene", status: "completed", latency_ms: Math.round(performance.now() - uploadStarted) },
          sessionId,
        );
        activeStage = "recognizing";
        stageStartedAt = performance.now();
      }
      let adaptedMode: ExecutionMode | null = null;
      if (currentSession.scene_asset_id !== sceneAssetId) {
        dispatch({ type: "patch", value: { sceneStage: "recognizing" } });
        const recognitionStarted = performance.now();
        const adapted = await soloShotApi.adaptReference(
          sessionId,
          currentSession.reference_asset.reference_id,
          sceneAssetId,
          keys.adapt,
          abortController.signal,
        );
        adaptedMode = adapted.executionMode;
        setLayout(adapted.data.target_layout);
        analytics.track(
          "agent_success",
          { mode: "scene_adaptation", status: "recognized", latency_ms: Math.round(performance.now() - recognitionStarted) },
          sessionId,
        );
      }
      activeStage = "generating";
      stageStartedAt = performance.now();
      dispatch({ type: "patch", value: { sceneStage: "generating" } });
      const run = await soloShotApi.createAgentRun(
        sessionId,
        "scene_adaptation",
        keys.plan,
        abortController.signal,
      );
      analytics.track(
        "shot_plan_view",
        { mode: "scene_adaptation", status: "generated", latency_ms: Math.round(performance.now() - stageStartedAt) },
        sessionId,
      );
      dispatch({
        type: "patch",
        value: {
          executionMode: run.executionMode ?? adaptedMode ?? "live",
          sceneStage: "idle",
        },
      });
      await analytics.flush(sessionId);
      await queryClient.invalidateQueries({ queryKey: ["session", sessionId] });
      navigate(`/session/${sessionId}/plan`);
    } catch (caught) {
      if (!isCurrentOperation()) {
        return;
      }
      if (
        (caught instanceof DOMException && caught.name === "AbortError") ||
        (caught instanceof SoloShotApiError && caught.code === "UPLOAD_CANCELED")
      ) {
        analytics.track(
          "reference_upload",
          { source: "scene", status: "canceled", latency_ms: Math.round(performance.now() - stageStartedAt) },
          sessionId,
        );
        void analytics.flush(sessionId);
        dispatch({ type: "patch", value: { sceneStage: "idle" } });
        return;
      }
      const errorCode = caught instanceof SoloShotApiError ? caught.code : "REQUEST_FAILED";
      analytics.track(
        activeStage === "uploading"
          ? "reference_upload"
          : activeStage === "recognizing"
            ? "agent_fail"
            : "shot_plan_view",
        {
          mode: "scene_adaptation",
          source: "scene",
          status: "failed",
          error_code: errorCode,
          latency_ms: Math.round(performance.now() - stageStartedAt),
        },
        sessionId,
      );
      void analytics.flush(sessionId);
      setError(caught);
      dispatch({ type: "patch", value: { executionMode: "error", sceneStage: "failed" } });
    } finally {
      if (isCurrentOperation()) {
        runningRef.current = false;
        controllerRef.current = null;
      }
    }
  }

  function selectScene(sceneMedia: NonNullable<typeof state.sceneMedia>): void {
    const keys = createSceneOperationKeys();
    setLayout(null);
    setProgress(0);
    dispatch({
      type: "patch",
      value: {
        sceneMedia,
        sceneAssetId: null,
        sceneStage: "uploading",
        sceneOperationKeys: keys,
      },
    });
    void runSceneFlow(session, sceneMedia, null, keys);
  }

  const stage = state.sceneStage;
  const locked = stage === "recognizing" || stage === "generating";

  return (
    <section className="page scene-page">
      <PageHeader title="让灵感，发生在你眼前" backTo={`/session/${sessionId}/analysis`} />
      <div className="page-intro">
        <Mountains size={28} aria-hidden="true" />
        <span>
          <p>拍下此刻的场景，SoloShot 会保留镜头感，重新安排机位与站位。</p>
        </span>
      </div>
      <StateNotice mode="live">现场素材仅用于本次 ShotPlan。</StateNotice>
      <MediaPicker
        value={state.sceneMedia}
        title="拍下你眼前的场景"
        disabled={locked}
        overlay={layout === null ? null : <TargetLayoutOverlay layout={layout} />}
        onChange={selectScene}
      />
      <SceneStageStatus
        stage={stage}
        progress={progress}
        onCancel={() => controllerRef.current?.abort()}
      />
      {error !== null ? (
        <AsyncError
          error={error}
          onRetry={() => {
            const keys = state.sceneOperationKeys ?? createSceneOperationKeys();
            void runSceneFlow(session, state.sceneMedia, state.sceneAssetId, keys);
          }}
        />
      ) : null}
    </section>
  );
}

function createSceneOperationKeys(): SceneOperationKeys {
  const operationId = crypto.randomUUID().replaceAll("-", "");
  return {
    uploadCreate: `h5-scene-upload-${operationId}`,
    uploadComplete: `h5-scene-complete-${operationId}`,
    adapt: `h5-scene-adapt-${operationId}`,
    plan: `h5-scene-plan-${operationId}`,
  };
}

function SceneStageStatus({
  stage,
  progress,
  onCancel,
}: {
  stage: SceneStage;
  progress: number;
  onCancel: () => void;
}) {
  if (stage === "uploading") {
    return <UploadProgress value={progress} label="正在上传现场图" onCancel={onCancel} />;
  }
  if (stage === "recognizing" || stage === "generating") {
    return (
      <div className="scene-stage-status" role="status" aria-live="polite">
        <CircleNotch className="spin" size={23} aria-hidden="true" />
        <span>
          <strong>
            {stage === "recognizing" ? "正在识别人物与构图" : "正在生成拍摄步骤"}
          </strong>
          <small>
            {stage === "recognizing"
              ? "现场图会一直保留在这里"
              : "人物布局已经识别完成"}
          </small>
        </span>
      </div>
    );
  }
  return null;
}

function TargetLayoutOverlay({
  layout,
}: {
  layout: ReferenceAnalysis["target_layout"];
}) {
  return (
    <div className="target-layout-overlay" aria-label="现场人物目标布局">
      <span
        className="target-layout-box"
        style={{
          left: `${(layout.center_x - layout.width / 2) * 100}%`,
          top: `${(layout.center_y - layout.height / 2) * 100}%`,
          width: `${layout.width * 100}%`,
          height: `${layout.height * 100}%`,
        }}
      />
      <span
        className="target-head-point"
        style={{ left: `${layout.head_point.x * 100}%`, top: `${layout.head_point.y * 100}%` }}
      />
      <span className="target-foot-line" style={{ top: `${layout.foot_line_y * 100}%` }} />
      <small>{layout.body_direction.replaceAll("_", " ")}</small>
    </div>
  );
}

function MediaImage({
  sessionId,
  mediaAssetId,
  alt,
}: {
  sessionId: string;
  mediaAssetId: string;
  alt: string;
}) {
  const access = useQuery({
    queryKey: ["media-access", mediaAssetId],
    queryFn: () => soloShotApi.getMediaAccess(sessionId, mediaAssetId),
    staleTime: 240_000,
  });
  if (access.isLoading) {
    return <div className="media-placeholder">正在准备画面…</div>;
  }
  if (access.error !== null || access.data === undefined) {
    return (
      <div className="media-placeholder media-expired" role="status">
        这张画面已无法显示，请重新开始。
      </div>
    );
  }
  return <img src={access.data.data.download_url} alt={alt} />;
}

function ReferenceImage({ session }: { session: SoloShotSession }) {
  const { state } = useFlow();
  const preset = findTestImageCase(state.caseId);
  if (session.reference_asset?.source_type === "preset" && preset !== null) {
    return <img src={preset.publicAssets.detail} alt={`${preset.title}参考画面`} />;
  }
  if (session.reference_asset?.media_asset_id !== null && session.reference_asset?.media_asset_id !== undefined) {
    return (
      <MediaImage
        sessionId={session.session_id}
        mediaAssetId={session.reference_asset.media_asset_id}
        alt="用户参考画面"
      />
    );
  }
  return <div className="media-placeholder">参考画面不可用</div>;
}

function SceneLayoutImage({
  sessionId,
  mediaAssetId,
  layout,
}: {
  sessionId: string;
  mediaAssetId: string;
  layout: ReferenceAnalysis["target_layout"];
}) {
  const access = useQuery({
    queryKey: ["media-access", mediaAssetId],
    queryFn: () => soloShotApi.getMediaAccess(sessionId, mediaAssetId),
    staleTime: 240_000,
  });
  if (access.isLoading) {
    return <div className="media-placeholder">正在准备现场画面…</div>;
  }
  if (access.error !== null || access.data === undefined) {
    return <div className="media-placeholder media-expired">现场画面已过期</div>;
  }
  const asset = access.data.data.asset;
  return (
    <div
      className="target-layout-preview"
      style={
        asset.width !== null && asset.height !== null
          ? { aspectRatio: `${asset.width} / ${asset.height}` }
          : undefined
      }
    >
      <img src={access.data.data.download_url} alt="现场构图预览" />
      <TargetLayoutOverlay layout={layout} />
    </div>
  );
}

export function PlanScreen() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { state } = useFlow();
  const { sessionId, query } = useSession();
  const iosExperienceTriggerRef = useRef<HTMLButtonElement>(null);
  const [iosExperienceState, setIosExperienceState] =
    useState<IOSExperienceState>("closed");
  if (query.isLoading) {
    return <Loading label="正在恢复 ShotPlan…" />;
  }
  if (query.error !== null || query.data === undefined) {
    return <AsyncError error={query.error} onRetry={() => void query.refetch()} />;
  }
  const session = query.data.data;
  const plan = session.shot_plan;
  if (plan === null) {
    return (
      <AsyncError
        error={new SoloShotApiError("ShotPlan 尚未生成。", "INVALID_STATE", true)}
        onRetry={() => navigate(`/session/${sessionId}/analysis`)}
      />
    );
  }
  const mode = modeForSession(session, state.executionMode);
  const existingHandoff =
    session.state === "handoff_ready" ? loadHandoffDraft(sessionId) : null;

  async function prepareHandoff(): Promise<void> {
    if (iosExperienceState === "creating") {
      return;
    }
    if (existingHandoff?.code !== undefined) {
      setIosExperienceState("closed");
      navigate(`/session/${sessionId}/handoff`);
      return;
    }

    const savedDraft = loadHandoffDraft(sessionId);
    const draft =
      savedDraft !== null && savedDraft.code === undefined
        ? savedDraft
        : createHandoffDraft(sessionId);
    setIosExperienceState("creating");
    try {
      const result = await soloShotApi.createHandoff(
        sessionId,
        draft.createIdempotencyKey,
      );
      const nextDraft = {
        ...draft,
        code: result.data.handoff.code,
        managementToken: result.data.management_token,
        qrPayload: result.data.qr_payload,
      };
      saveHandoffDraft(nextDraft);
      analytics.track(
        "handoff_qr_create",
        { mode: result.data.handoff.mode },
        sessionId,
      );
      void analytics.flush(sessionId);
      await queryClient.invalidateQueries({ queryKey: ["session", sessionId] });
      setIosExperienceState("closed");
      navigate(`/session/${sessionId}/handoff`);
    } catch {
      setIosExperienceState("error");
    }
  }

  return (
    <section className="page plan-page">
      <PageHeader title="你的专属 ShotPlan" backTo={`/session/${sessionId}/analysis`} />
      <div className="plan-reference">
        {session.mode === "scene_adaptation" && session.scene_asset_id != null ? (
          <SceneLayoutImage
            sessionId={sessionId}
            mediaAssetId={session.scene_asset_id}
            layout={plan.target_layout}
          />
        ) : (
          <div className="target-layout-preview">
            <ReferenceImage session={session} />
          </div>
        )}
        <span>
          <small>{session.mode === "scene_adaptation" ? "现场站位已经安排好" : "这就是你要留下的画面"}</small>
          <strong>{poseLabel(plan.target_layout.pose_template)}</strong>
        </span>
      </div>
      <StateNotice mode={mode}>
        ShotPlan 已就绪
      </StateNotice>
      <div className="plan-facts">
        <span>
          <DeviceMobile size={20} aria-hidden="true" />
          <strong>手机放置位置</strong>
          <small>{cameraHeightLabel(plan.camera_height)} · {cameraAngleLabel(plan.camera_angle)}</small>
        </span>
        <span>
          <Camera size={20} aria-hidden="true" />
          <strong>这样取景</strong>
          <small>{lensLabel(plan.lens)} · {captureModeLabel(plan.capture_mode)}</small>
        </span>
      </div>
      <div className="plan-card">
        <p>{plan.phone_setup_instruction}</p>
        <ol>
          {plan.action_script.map((step) => (
            <li key={step.sequence}>
              <span>{step.sequence}</span>
              <strong>{step.instruction}</strong>
              <small>{step.duration_seconds} 秒</small>
            </li>
          ))}
        </ol>
      </div>
      <button
        ref={iosExperienceTriggerRef}
        type="button"
        className="primary-button"
        onClick={() => setIosExperienceState("open")}
      >
        <DeviceMobile size={20} aria-hidden="true" /> 让 iPhone 现场陪我拍
      </button>
      <button
        type="button"
        className="secondary-button"
        disabled={session.state === "handoff_ready"}
        onClick={() => {
          setLiveCoachPreference(sessionId, true);
          navigate(`/session/${sessionId}/live-check/1`);
        }}
      >
        浏览器免安装陪拍 <Camera size={20} aria-hidden="true" />
      </button>
      <button
        type="button"
        className="tertiary-button"
        disabled={session.state === "handoff_ready"}
        onClick={() => navigate(`/session/${sessionId}/capture/1`)}
      >
        直接拍照或上传 <ArrowRight size={20} aria-hidden="true" />
      </button>
      {session.state === "handoff_ready" ? (
        <p className="handoff-plan-note">任务已交给 iPhone；取消接力后可回到网页继续。</p>
      ) : null}
      <IOSExperienceSheet
        state={iosExperienceState}
        hasExistingHandoff={existingHandoff?.code !== undefined}
        triggerRef={iosExperienceTriggerRef}
        onClose={() => setIosExperienceState("closed")}
        onConfirm={() => void prepareHandoff()}
        onContinueOnWeb={() => {
          setIosExperienceState("closed");
          navigate(`/session/${sessionId}/capture/1`);
        }}
      />
    </section>
  );
}

export function CaptureScreen() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const params = useParams<{ round: string }>();
  const round = params.round === "2" ? 2 : 1;
  const { state, dispatch } = useFlow();
  const { sessionId, query } = useSession();
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<unknown>(null);
  const [controller, setController] = useState<AbortController | null>(null);

  if (query.isLoading) {
    return <Loading />;
  }
  if (query.error !== null || query.data === undefined) {
    return <AsyncError error={query.error} onRetry={() => void query.refetch()} />;
  }
  const session = query.data.data;
  if (session.state === "handoff_ready") {
    return (
      <section className="page capture-page">
        <PageHeader
          title={round === 1 ? "第一次，先完整拍下来" : "第二次，只改最关键的一点"}
          backTo={`/session/${sessionId}/plan`}
        />
        <AsyncError
          error={new SoloShotApiError(
            "此任务正在接力到 iPhone，请先撤销任务码再回到网页拍摄。",
            "INVALID_STATE",
            true,
          )}
          onRetry={() => navigate(`/session/${sessionId}/handoff`)}
        />
      </section>
    );
  }
  const fixture =
    session.mode === "original_replication" && session.reference_asset?.source_type === "preset";
  const localMedia = state.captureMedia[round] ?? null;

  async function evaluate(): Promise<void> {
    const abortController = new AbortController();
    setController(abortController);
    setBusy(true);
    setError(null);
    try {
      let capture: Capture;
      if (fixture) {
        const caseId = state.caseId;
        if (caseId === null) {
          throw new SoloShotApiError("精选样例已失效，请重新开始。", "INVALID_STATE", true);
        }
        capture = (await soloShotApi.createFixtureCapture(sessionId, caseId, round)).data;
        setProgress(55);
      } else {
        if (localMedia === null) {
          throw new SoloShotApiError(
            "刷新后尚未提交的本地拍摄文件无法恢复，请重新选择。",
            "MEDIA_NOT_READY",
            true,
          );
        }
        const media = await soloShotApi.uploadMedia(sessionId, "capture", localMedia.blob, {
          signal: abortController.signal,
          onProgress: (value) => setProgress(Math.round(value * 0.72)),
        });
        capture = (await soloShotApi.createCapture(sessionId, media.media_asset_id, round)).data;
        setProgress(78);
      }
      const evaluation = await soloShotApi.createEvaluation(sessionId, capture.capture_id);
      setProgress(100);
      dispatch({
        type: "patch",
        value: { executionMode: evaluation.executionMode ?? (fixture ? "fixture" : "live") },
      });
      analytics.track(
        "result_evaluated",
        {
          round_index: round,
          execution_mode: evaluation.executionMode ?? (fixture ? "fixture" : "live"),
        },
        sessionId,
      );
      await analytics.flush(sessionId);
      await queryClient.invalidateQueries({ queryKey: ["session", sessionId] });
      navigate(`/session/${sessionId}/evaluation/${round}`);
    } catch (caught) {
      setError(caught);
      dispatch({ type: "patch", value: { executionMode: "error" } });
    } finally {
      setBusy(false);
      setController(null);
    }
  }

  return (
    <section className="page capture-page">
      <PageHeader
        title={round === 1 ? "第一次，先完整拍下来" : "第二次，只改最关键的一点"}
        backTo={`/session/${sessionId}/plan`}
      />
      <div className="page-intro">
        <Camera size={28} aria-hidden="true" />
        <span>
          <p>
            {round === 1
              ? "跟着 ShotPlan 完成第一张作品。"
              : "保留上一轮做对的，只调整 SoloShot 指出的那一步。"}
          </p>
        </span>
      </div>
      {fixture ? (
        <>
          <StateNotice mode="fixture">
            当前结果来自精选样例，不代表 AI 对本次照片的判断。
          </StateNotice>
          <div className="fixture-capture-card">
            <Sparkle size={28} weight="fill" aria-hidden="true" />
            <strong>{round === 1 ? "第一次建议已准备好" : "看看调整后的变化"}</strong>
            <small>体验一次完整的旅拍优化节奏。</small>
          </div>
        </>
      ) : (
        <MediaPicker
          value={localMedia}
          title={round === 1 ? "加入第一次成片" : "加入调整后的成片"}
          onChange={(value) => dispatch({ type: "capture", round, value })}
        />
      )}
      {busy ? <UploadProgress value={progress} onCancel={() => controller?.abort()} /> : null}
      {error !== null ? <AsyncError error={error} onRetry={() => void evaluate()} /> : null}
      <button
        type="button"
        className="primary-button"
        disabled={busy || (!fixture && localMedia === null)}
        onClick={() => void evaluate()}
      >
        {busy
          ? "AI 摄影导演正在复盘…"
          : fixture
            ? round === 1
              ? "查看第一次建议"
              : "查看第二次变化"
            : "看看这一拍"}
        <ArrowRight size={20} aria-hidden="true" />
      </button>
    </section>
  );
}

const issueLabels: Readonly<Record<string, string>> = {
  person_too_large: "人物比例偏大",
  person_too_small: "人物比例偏小",
  person_too_left: "人物位置偏左",
  person_too_right: "人物位置偏右",
  head_cut: "头部未完整入镜",
  feet_cut: "脚部未完整入镜",
  background_blocked: "背景主体被遮挡",
  pose_direction_wrong: "身体朝向不对",
  arm_position_wrong: "手臂动作需要调整",
  camera_too_high: "机位偏高",
  camera_too_low: "机位偏低",
  camera_angle_wrong: "镜头角度不对",
  motion_timing_wrong: "动作时机不对",
};

function EvaluationCard({ evaluation, round }: { evaluation: ResultEvaluation; round: number }) {
  if (evaluation.goal_satisfied) {
    return (
      <div className="evaluation-success">
        <CheckCircle size={34} weight="fill" aria-hidden="true" />
        <span>
          <strong>这一次，你拍到了</strong>
          <small>作品就绪度 {Math.round(evaluation.publish_readiness * 100)}%</small>
        </span>
      </div>
    );
  }
  return (
    <>
      <div className="issue-card">
        <p>最值得调整的是</p>
        <h2>{issueLabels[evaluation.issue_code ?? ""] ?? "仍可继续改进"}</h2>
        <span>{evaluation.top_issue ?? "本轮已完成，请查看结果。"}</span>
      </div>
      {evaluation.next_instruction !== undefined ? (
        <div className="instruction-card">
          <Footprints size={24} weight="fill" aria-hidden="true" />
          <span>
            <small>下一拍，照这一句做</small>
            <strong>{evaluation.next_instruction}</strong>
          </span>
        </div>
      ) : null}
    </>
  );
}

export function EvaluationScreen() {
  const navigate = useNavigate();
  const params = useParams<{ round: string }>();
  const round = params.round === "2" ? 2 : 1;
  const { state } = useFlow();
  const { sessionId, query } = useSession();
  if (query.isLoading) {
    return <Loading label="正在找回上一轮建议…" />;
  }
  if (query.error !== null || query.data === undefined) {
    return <AsyncError error={query.error} onRetry={() => void query.refetch()} />;
  }
  const session = query.data.data;
  const evaluation = session.evaluations[round - 1] ??
    (session.capture_rounds.at(-1)?.round_index === round ? session.evaluation : null);
  if (evaluation === null || evaluation === undefined) {
    return (
      <AsyncError
        error={new SoloShotApiError("本轮评价尚未完成。", "INVALID_STATE", true)}
        onRetry={() => navigate(`/session/${sessionId}/capture/${round}`)}
      />
    );
  }
  const mode = modeForSession(session, state.executionMode);
  const liveCoach = prefersLiveCoach(sessionId);
  const capture = session.capture_rounds.find((item) => item.round_index === round);
  const hasRealCapture = capture !== undefined && !capture.media_asset_id.startsWith("media_fixture_");
  return (
    <section className="page evaluation-page">
      <PageHeader
        title={evaluation.goal_satisfied ? "这一次，你拍到了" : "这一拍，可以更好"}
        backTo={
          liveCoach
            ? `/session/${sessionId}/live-check/${round}`
            : `/session/${sessionId}/capture/${round}`
        }
      />
      <StateNotice mode={mode}>
        {mode === "fixture"
          ? hasRealCapture
            ? "照片来自本次浏览器拍摄；作品就绪度为精选样例参考，不代表 AI 对照片的判断。"
            : "以下结果来自精选样例。"
          : "这条建议来自本次成片。"}
      </StateNotice>
      {(mode === "live" || hasRealCapture) && capture !== undefined ? (
        <div className="capture-result-image">
          <MediaImage
            sessionId={sessionId}
            mediaAssetId={capture.media_asset_id}
            alt={round === 1 ? "第一次成片" : "调整后的成片"}
          />
        </div>
      ) : null}
      <EvaluationCard evaluation={evaluation} round={round} />
      {!evaluation.goal_satisfied && round === 1 ? (
        <p className="single-change-rule">其他都保持不变。</p>
      ) : null}
      <button
        type="button"
        className="primary-button"
        onClick={() =>
          navigate(
            evaluation.goal_satisfied || round === 2
              ? `/session/${sessionId}/result`
              : liveCoach
                ? `/session/${sessionId}/live-check/2`
                : `/session/${sessionId}/capture/2`,
          )
        }
      >
        {evaluation.goal_satisfied || round === 2 ? "查看我的作品" : "带着这条建议再拍一次"}
        {evaluation.goal_satisfied || round === 2 ? (
          <ArrowRight size={20} aria-hidden="true" />
        ) : (
          <Repeat size={19} aria-hidden="true" />
        )}
      </button>
    </section>
  );
}

function RoundMedia({
  session,
  item,
}: {
  session: SoloShotSession;
  item: Exclude<ResultComparisonItem, { kind: "reference" }>;
}) {
  return (
    <div className="round-media">
      <MediaImage
        sessionId={session.session_id}
        mediaAssetId={item.capture.media_asset_id}
        alt={item.accessibilityLabel}
      />
      <strong>{item.label}</strong>
    </div>
  );
}

function ReferenceResultMedia({ session }: { session: SoloShotSession }) {
  return (
    <div className="round-media reference-media">
      <ReferenceImage session={session} />
      <strong>参考</strong>
    </div>
  );
}

export function ResultScreen() {
  const navigate = useNavigate();
  const { state, reset } = useFlow();
  const { sessionId, query } = useSession();
  if (query.isLoading) {
    return <Loading label="正在整理你的作品…" />;
  }
  if (query.error !== null || query.data === undefined) {
    return <AsyncError error={query.error} onRetry={() => void query.refetch()} />;
  }
  const session = query.data.data;
  const mode = modeForSession(session, state.executionMode);
  const evaluations = session.evaluations;
  const first = evaluations[0];
  const latest = evaluations.at(-1);
  const satisfied = latest?.goal_satisfied === true;
  const realCaptures = session.capture_rounds.filter(
    (capture) => !capture.media_asset_id.startsWith("media_fixture_"),
  );
  const displayedCaptures = mode === "live" ? session.capture_rounds : realCaptures;
  const comparisonItems = buildResultComparisonItems(displayedCaptures);
  const hasRealCaptureMedia = realCaptures.length > 0;
  return (
    <section className="page result-page">
      <div className="result-heading">
        <span>
          {satisfied ? <Check size={30} weight="bold" /> : <Sparkle size={30} weight="fill" />}
        </span>
        <h1>
          {mode === "fixture"
            ? "一次调整，画面已经不同"
            : satisfied
              ? "你把喜欢的瞬间，拍成了自己的作品"
              : "这次旅拍，已经有了自己的样子"}
        </h1>
        <p>
          {mode === "fixture"
            ? "从第一拍到第二拍，SoloShot 只让你改最关键的一步。"
            : satisfied
              ? "灵感、现场与动作，终于落在同一张画面里。"
              : "已经完成两次拍摄，把这份 ShotPlan 留给下一次继续。"}
        </p>
      </div>
      <StateNotice mode={mode}>
        {mode === "fixture"
          ? hasRealCaptureMedia
            ? "照片来自本次拍摄，作品就绪度为演示参考，不代表 AI 对照片的判断。"
            : "作品就绪度来自精选样例，不生成虚构的前后对比照片。"
          : "这里展示的照片都来自本次旅拍。"}
      </StateNotice>

      {mode === "live" || hasRealCaptureMedia ? (
        <div className="live-comparison">
          {comparisonItems.map((item) =>
            item.kind === "reference" ? (
              <ReferenceResultMedia key={item.kind} session={session} />
            ) : (
              <RoundMedia key={item.capture.capture_id} session={session} item={item} />
            ),
          )}
        </div>
      ) : (
        <div className="fixture-score-grid">
          {evaluations.map((evaluation, index) => (
            <div key={evaluation.evaluation_id}>
              {index === 0 ? <Warning size={25} weight="fill" /> : <CheckCircle size={25} weight="fill" />}
              <strong>{roundLabel(index + 1)}</strong>
              <small>{Math.round(evaluation.publish_readiness * 100)}% 作品就绪度</small>
            </div>
          ))}
        </div>
      )}

      {first !== undefined && latest !== undefined ? (
        <div className="readiness-card">
          <span>
            <strong>作品就绪度</strong>
            <small>
              {Math.round(first.publish_readiness * 100)}% → {Math.round(latest.publish_readiness * 100)}%
            </small>
          </span>
          <div aria-label={`作品就绪度 ${Math.round(latest.publish_readiness * 100)}%`}>
            <span style={{ width: `${latest.publish_readiness * 100}%` }} />
          </div>
        </div>
      ) : null}

      <button
        type="button"
        className="primary-button"
        onClick={() => {
          reset();
          navigate("/");
        }}
      >
        开始下一次旅拍 <ArrowRight size={20} aria-hidden="true" />
      </button>
      <p className="retention-note">临时素材将在 24 小时后自动清理。</p>
    </section>
  );
}

export function NotFoundScreen() {
  const navigate = useNavigate();
  return (
    <section className="page">
      <div className="center-state error-state">
        <Warning size={34} weight="fill" aria-hidden="true" />
        <strong>这段旅程走丢了</strong>
        <button type="button" className="secondary-button" onClick={() => navigate("/")}>
          回到 SoloShot
        </button>
      </div>
    </section>
  );
}
