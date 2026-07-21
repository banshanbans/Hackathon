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
  ShieldCheck,
  Sparkle,
  Warning,
} from "@phosphor-icons/react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import {
  SoloShotApiError,
  soloShotApi,
  type Capture,
  type ExecutionMode,
  type ResultEvaluation,
  type SoloShotSession,
} from "../apiClient";
import { analytics } from "../analytics";
import { PageHeader, StateNotice } from "../components/AppChrome";
import { MediaPicker, UploadProgress } from "../components/MediaPicker";
import { findTestImageCase } from "../dataset";
import { useFlow } from "../flow/FlowProvider";
import {
  cameraAngleLabel,
  cameraHeightLabel,
  captureModeLabel,
  lensLabel,
  poseLabel,
  productErrorCopy,
  roundLabel,
} from "../productCopy";

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

  async function adapt(): Promise<void> {
    if (state.sceneMedia === null || session.reference_asset === null) {
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
    setController(abortController);
    setBusy(true);
    setError(null);
    try {
      let sceneAssetId = state.sceneAssetId;
      if (sceneAssetId === null) {
        const media = await soloShotApi.uploadMedia(sessionId, "scene", state.sceneMedia.blob, {
          signal: abortController.signal,
          onProgress: setProgress,
        });
        sceneAssetId = media.media_asset_id;
        dispatch({ type: "patch", value: { sceneAssetId } });
      } else {
        setProgress(80);
      }
      const adapted = await soloShotApi.adaptReference(
        sessionId,
        session.reference_asset.reference_id,
        sceneAssetId,
      );
      setProgress(92);
      const run = await soloShotApi.createAgentRun(sessionId, "scene_adaptation");
      setProgress(100);
      dispatch({
        type: "patch",
        value: { executionMode: run.executionMode ?? adapted.executionMode ?? "live" },
      });
      await queryClient.invalidateQueries({ queryKey: ["session", sessionId] });
      navigate(`/session/${sessionId}/plan`);
    } catch (caught) {
      setError(caught);
      dispatch({ type: "patch", value: { executionMode: "error" } });
    } finally {
      setBusy(false);
      setController(null);
    }
  }

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
        onChange={(sceneMedia) =>
          dispatch({ type: "patch", value: { sceneMedia, sceneAssetId: null } })
        }
      />
      {busy ? <UploadProgress value={progress} onCancel={() => controller?.abort()} /> : null}
      {error !== null ? <AsyncError error={error} onRetry={() => void adapt()} /> : null}
      <button
        type="button"
        className="primary-button"
        disabled={busy || state.sceneMedia === null}
        onClick={() => void adapt()}
      >
        {busy ? "正在为这个场景重新设计…" : "为此刻生成 ShotPlan"}
        <ArrowRight size={20} aria-hidden="true" />
      </button>
    </section>
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

export function PlanScreen() {
  const navigate = useNavigate();
  const { state } = useFlow();
  const { sessionId, query } = useSession();
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
  return (
    <section className="page plan-page">
      <PageHeader title="你的专属 ShotPlan" backTo={`/session/${sessionId}/analysis`} />
      <div className="plan-reference">
        <ReferenceImage session={session} />
        <span>
          <small>这就是你要留下的画面</small>
          <strong>{poseLabel(plan.target_layout.pose_template)}</strong>
        </span>
      </div>
      <StateNotice mode={mode}>
        ShotPlan 已就绪
      </StateNotice>
      <div className="plan-facts">
        <span>
          <DeviceMobile size={20} aria-hidden="true" />
          <strong>手机放这里</strong>
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
      <div className="safety-card">
        <ShieldCheck size={22} weight="fill" aria-hidden="true" />
        <span>
          <strong>出发前，再确认一件事</strong>
          <small>{plan.safety_notes[0]}</small>
        </span>
      </div>
      <button
        type="button"
        className="primary-button"
        onClick={() => navigate(`/session/${sessionId}/handoff`)}
      >
        <DeviceMobile size={20} aria-hidden="true" /> 让 iPhone 现场陪我拍
      </button>
      <button
        type="button"
        className="secondary-button"
        disabled={session.state === "handoff_ready"}
        onClick={() => navigate(`/session/${sessionId}/capture/1`)}
      >
        继续在网页完成 <ArrowRight size={20} aria-hidden="true" />
      </button>
      {session.state === "handoff_ready" ? (
        <p className="handoff-plan-note">任务已交给 iPhone；取消接力后可回到网页继续。</p>
      ) : null}
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
  const capture = session.capture_rounds.find((item) => item.round_index === round);
  return (
    <section className="page evaluation-page">
      <PageHeader
        title={evaluation.goal_satisfied ? "这一次，你拍到了" : "这一拍，可以更好"}
        backTo={`/session/${sessionId}/capture/${round}`}
      />
      <StateNotice mode={mode}>
        {mode === "fixture"
          ? "以下结果来自精选样例。"
          : "这条建议来自本次成片。"}
      </StateNotice>
      {mode === "live" && capture !== undefined ? (
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

function RoundMedia({ session, capture }: { session: SoloShotSession; capture: Capture }) {
  return (
    <div className="round-media">
      <MediaImage
        sessionId={session.session_id}
        mediaAssetId={capture.media_asset_id}
        alt={capture.round_index === 1 ? "第一次成片" : "调整后的成片"}
      />
      <strong>{roundLabel(capture.round_index)}</strong>
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
          {(mode === "live" ? session.capture_rounds : realCaptures).map((capture) => (
            <RoundMedia key={capture.capture_id} session={session} capture={capture} />
          ))}
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
