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

function Loading({ label = "正在恢复任务…" }: { label?: string }) {
  return (
    <div className="center-state" role="status">
      <CircleNotch className="spin" size={34} aria-hidden="true" />
      <strong>{label}</strong>
      <small>以服务端 Session 状态为准</small>
    </div>
  );
}

function AsyncError({ error, onRetry }: { error: unknown; onRetry: () => void }) {
  const apiError =
    error instanceof SoloShotApiError
      ? error
      : new SoloShotApiError("当前步骤没有完成。", "REQUEST_FAILED", true);
  return (
    <div className="center-state error-state" role="alert">
      <Warning size={34} weight="fill" aria-hidden="true" />
      <strong>{apiError.message}</strong>
      <code>{apiError.code}</code>
      <small>没有静默切换到 Fixture。</small>
      {apiError.recoverable ? (
        <button type="button" className="secondary-button" onClick={onRetry}>
          <Repeat size={18} aria-hidden="true" /> 重试
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
    return <Loading label="正在读取参考分析…" />;
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
      <PageHeader title="参考分析" backTo="/constraints" />
      <div className="analysis-success">
        <span>
          <Check size={28} weight="bold" aria-hidden="true" />
        </span>
        <p className="kicker">ACTIVE ANALYSIS</p>
        <h1>参考画面已经理解完成</h1>
        <p>后续步骤会复用这份 active analysis，不会再次调用参考理解。</p>
      </div>
      <StateNotice mode={mode}>
        {mode === "fixture"
          ? "预设原图复刻使用确定性 ShotPlan。"
          : "当前分析来自 Live 路径；刷新后可从 Session 继续。"}
      </StateNotice>
      <div className="analysis-facts">
        <span>
          <strong>模式</strong>
          <small>{session.mode === "original_replication" ? "原图复刻" : "场景适配"}</small>
        </span>
        <span>
          <strong>参考状态</strong>
          <small>{session.active_reference_analysis_id === null ? "待恢复" : "已激活"}</small>
        </span>
      </div>

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
          ? "正在生成 ShotPlan…"
          : session.mode === "scene_adaptation"
            ? "添加当前现场"
            : "生成 ShotPlan"}
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
      const media = await soloShotApi.uploadMedia(sessionId, "scene", state.sceneMedia.blob, {
        signal: abortController.signal,
        onProgress: setProgress,
      });
      const adapted = await soloShotApi.adaptReference(
        sessionId,
        session.reference_asset.reference_id,
        media.media_asset_id,
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
      <PageHeader title="添加当前现场" backTo={`/session/${sessionId}/analysis`} />
      <div className="page-intro">
        <Mountains size={28} aria-hidden="true" />
        <span>
          <h1>让参考构图适应你眼前的环境</h1>
          <p>现场图只用于重新规划人物位置与机位，不改变原参考意图。</p>
        </span>
      </div>
      <StateNotice mode="live">场景适配始终走方舟 Live；未配置 Provider 时会明确报错。</StateNotice>
      <MediaPicker
        value={state.sceneMedia}
        title="拍摄或选择当前现场"
        onChange={(sceneMedia) => dispatch({ type: "patch", value: { sceneMedia } })}
      />
      {busy ? <UploadProgress value={progress} onCancel={() => controller?.abort()} /> : null}
      {error !== null ? <AsyncError error={error} onRetry={() => void adapt()} /> : null}
      <button
        type="button"
        className="primary-button"
        disabled={busy || state.sceneMedia === null}
        onClick={() => void adapt()}
      >
        {busy ? "正在重新规划…" : "适配现场并生成 ShotPlan"}
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
    return <div className="media-placeholder">正在获取短期预览…</div>;
  }
  if (access.error !== null || access.data === undefined) {
    return (
      <div className="media-placeholder media-expired" role="status">
        媒体已过期或不可访问，请重新开始。
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
      <PageHeader title="ShotPlan 拍摄任务" backTo={`/session/${sessionId}/analysis`} />
      <div className="plan-reference">
        <ReferenceImage session={session} />
        <span>
          <small>目标构图</small>
          <strong>{plan.target_layout.pose_template}</strong>
        </span>
      </div>
      <StateNotice mode={mode}>
        Agent 已完成 · {session.selected_skills.map((item) => item.name).join(" → ")}
      </StateNotice>
      <div className="plan-facts">
        <span>
          <DeviceMobile size={20} aria-hidden="true" />
          <strong>机位</strong>
          <small>{plan.camera_height} · {plan.camera_angle}</small>
        </span>
        <span>
          <Camera size={20} aria-hidden="true" />
          <strong>镜头</strong>
          <small>{plan.lens} · {plan.capture_mode}</small>
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
          <strong>安全检查</strong>
          <small>{plan.safety_notes[0]}</small>
        </span>
      </div>
      <button
        type="button"
        className="primary-button"
        onClick={() => navigate(`/session/${sessionId}/handoff`)}
      >
        <DeviceMobile size={20} aria-hidden="true" /> 在 iPhone 继续
      </button>
      <button
        type="button"
        className="secondary-button"
        disabled={session.state === "handoff_ready"}
        onClick={() => navigate(`/session/${sessionId}/capture/1`)}
      >
        留在网页拍摄 <ArrowRight size={20} aria-hidden="true" />
      </button>
      {session.state === "handoff_ready" ? (
        <p className="handoff-plan-note">接力期间网页拍摄已锁定；先在接力页撤销任务码才能恢复。</p>
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
        <PageHeader title={`第 ${round} 轮拍摄`} backTo={`/session/${sessionId}/plan`} />
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
          throw new SoloShotApiError("Fixture 案例标识已丢失，请重新开始。", "INVALID_STATE", true);
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
      <PageHeader title={`第 ${round} 轮拍摄`} backTo={`/session/${sessionId}/plan`} />
      <div className="page-intro">
        <Camera size={28} aria-hidden="true" />
        <span>
          <h1>{round === 1 ? "按 ShotPlan 完成首拍" : "只修正上一轮的一个问题"}</h1>
          <p>拍照和相册上传始终是 H5 的可靠后备；视频会在浏览器内抽帧。</p>
        </span>
      </div>
      {fixture ? (
        <>
          <StateNotice mode="fixture">
            该预设没有真实 Round 1 / Round 2 配对图，本页只运行确定性评分卡，不接收照片冒充 Live 判断。
          </StateNotice>
          <div className="fixture-capture-card">
            <Sparkle size={28} weight="fill" aria-hidden="true" />
            <strong>运行第 {round} 轮 Fixture 评价</strong>
            <small>结果来自 test-image-v1 固定案例。</small>
          </div>
        </>
      ) : (
        <MediaPicker
          value={localMedia}
          title={`添加第 ${round} 轮拍摄结果`}
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
        {busy ? "正在评价…" : fixture ? `运行第 ${round} 轮评分` : "上传并评价"}
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
          <strong>第 {round} 轮已达到目标</strong>
          <small>发布准备度 {Math.round(evaluation.publish_readiness * 100)}%</small>
        </span>
      </div>
    );
  }
  return (
    <>
      <div className="issue-card">
        <p>本次唯一主要问题</p>
        <h2>{issueLabels[evaluation.issue_code ?? ""] ?? "仍可继续改进"}</h2>
        <span>{evaluation.top_issue ?? "本轮已完成，请查看结果。"}</span>
      </div>
      {evaluation.next_instruction !== undefined ? (
        <div className="instruction-card">
          <Footprints size={24} weight="fill" aria-hidden="true" />
          <span>
            <small>下一步唯一指令</small>
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
    return <Loading label="正在恢复评价…" />;
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
      <PageHeader title={`第 ${round} 轮评价`} backTo={`/session/${sessionId}/capture/${round}`} />
      <StateNotice mode={mode}>
        {mode === "fixture"
          ? "演示评分卡，不代表真实照片比较。"
          : "评价使用参考媒体、active analysis、ShotPlan 与本轮拍摄。"}
      </StateNotice>
      {mode === "live" && capture !== undefined ? (
        <div className="capture-result-image">
          <MediaImage
            sessionId={sessionId}
            mediaAssetId={capture.media_asset_id}
            alt={`第 ${round} 轮真实拍摄`}
          />
        </div>
      ) : null}
      <EvaluationCard evaluation={evaluation} round={round} />
      {!evaluation.goal_satisfied && round === 1 ? (
        <p className="single-change-rule">只改这一点，其他位置、距离和动作保持不变。</p>
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
        {evaluation.goal_satisfied || round === 2 ? "查看最终结果" : "按建议再拍一次"}
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
        alt={`第 ${capture.round_index} 轮真实拍摄`}
      />
      <strong>Round {capture.round_index}</strong>
    </div>
  );
}

export function ResultScreen() {
  const navigate = useNavigate();
  const { state, reset } = useFlow();
  const { sessionId, query } = useSession();
  if (query.isLoading) {
    return <Loading label="正在恢复结果…" />;
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
        <p className="kicker">TWO-ROUND RESULT</p>
        <h1>{mode === "fixture" ? "两轮拍摄结果" : satisfied ? "目标已满足" : "两轮拍摄已完成"}</h1>
        <p>
          {mode === "fixture"
            ? "照片可以是真实拍摄，但以下建议和准备度来自固定演示数据。"
            : satisfied
              ? "本次任务可以结束。"
              : "第二轮仍有改进空间；系统不会伪造达标结论。"}
        </p>
      </div>
      <StateNotice mode={mode}>
        {mode === "fixture"
          ? hasRealCaptureMedia
            ? "以下照片来自本 Session；评分是 Fixture 固定演示，不代表模型比较。"
            : "仅展示评分变化卡；没有真实配对图时不生成 Before / After 照片。"
          : "以下图片来自本 Session 的真实 Round 1 / Round 2 上传。"}
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
              <strong>Round {index + 1}</strong>
              <small>{Math.round(evaluation.publish_readiness * 100)}% 准备度</small>
            </div>
          ))}
        </div>
      )}

      {first !== undefined && latest !== undefined ? (
        <div className="readiness-card">
          <span>
            <strong>发布准备度</strong>
            <small>
              {Math.round(first.publish_readiness * 100)}% → {Math.round(latest.publish_readiness * 100)}%
              {mode === "fixture" ? "（Fixture）" : ""}
            </small>
          </span>
          <div aria-label={`发布准备度 ${Math.round(latest.publish_readiness * 100)}%`}>
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
        开始新的任务 <ArrowRight size={20} aria-hidden="true" />
      </button>
      <p className="retention-note">Session 临时媒体默认保留 24 小时；可通过删除 Session 立即清理。</p>
    </section>
  );
}

export function NotFoundScreen() {
  const navigate = useNavigate();
  return (
    <section className="page">
      <div className="center-state error-state">
        <Warning size={34} weight="fill" aria-hidden="true" />
        <strong>没有找到这个页面</strong>
        <button type="button" className="secondary-button" onClick={() => navigate("/")}>
          返回首页
        </button>
      </div>
    </section>
  );
}
