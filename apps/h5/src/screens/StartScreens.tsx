import {
  ArrowRight,
  Camera,
  CheckCircle,
  ImageSquare,
  Mountains,
  Repeat,
  Sparkle,
  Suitcase,
  UploadSimple,
  User,
  Warning,
} from "@phosphor-icons/react";
import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  SoloShotApiError,
  soloShotApi,
  type ReferenceAsset,
  type UserConstraints,
} from "../apiClient";
import { analytics } from "../analytics";
import { MediaPicker, UploadProgress } from "../components/MediaPicker";
import { PageHeader, StateNotice } from "../components/AppChrome";
import { SelectionEditor } from "../components/SelectionEditor";
import { findTestImageCase, testImageDataset, type TestImageCase } from "../dataset";
import { useFlow, type FlowMode, type ReferenceSource } from "../flow/FlowProvider";

function PresetCard({ item, onClick }: { item: TestImageCase; onClick: () => void }) {
  return (
    <button type="button" className="preset-card" onClick={onClick}>
      <img src={item.publicAssets.thumbnail} alt="" />
      <span>
        <strong>{item.title}</strong>
        <small>{item.subtitle}</small>
      </span>
      <ArrowRight size={18} aria-hidden="true" />
    </button>
  );
}

export function EntryScreen() {
  const navigate = useNavigate();
  const { state, dispatch } = useFlow();

  useEffect(() => {
    analytics.track("page_view", { route: "/" });
  }, []);

  function chooseMode(mode: FlowMode): void {
    dispatch({ type: "patch", value: { mode } });
    analytics.track("mode_select", { mode });
  }

  function chooseSource(referenceSource: ReferenceSource): void {
    dispatch({ type: "patch", value: { referenceSource } });
  }

  return (
    <section className="page entry-page">
      <div className="hero-card">
        <p className="kicker">W2 · H5 END-TO-END</p>
        <h1>从参考画面，到第二次拍得更好。</h1>
        <p>无需登录。预设原图复刻可直接体验 Fixture；自定义和场景适配使用方舟 Live。</p>
      </div>

      <fieldset className="option-group">
        <legend>1. 选择拍摄模式</legend>
        <button
          type="button"
          className={state.mode === "original_replication" ? "option-card selected" : "option-card"}
          onClick={() => chooseMode("original_replication")}
        >
          <Sparkle size={24} aria-hidden="true" />
          <span>
            <strong>原图复刻</strong>
            <small>复制人物位置、比例、机位与动作方向</small>
          </span>
          {state.mode === "original_replication" ? <CheckCircle weight="fill" /> : null}
        </button>
        <button
          type="button"
          className={state.mode === "scene_adaptation" ? "option-card selected" : "option-card"}
          onClick={() => chooseMode("scene_adaptation")}
        >
          <Mountains size={24} aria-hidden="true" />
          <span>
            <strong>场景适配</strong>
            <small>保留参考意图，按当前现场重新规划</small>
          </span>
          {state.mode === "scene_adaptation" ? <CheckCircle weight="fill" /> : null}
        </button>
      </fieldset>

      <fieldset className="option-group compact-options">
        <legend>2. 参考来源</legend>
        <button
          type="button"
          className={state.referenceSource === "preset" ? "source-button selected" : "source-button"}
          onClick={() => chooseSource("preset")}
        >
          <ImageSquare size={21} aria-hidden="true" />
          预设参考
        </button>
        <button
          type="button"
          className={state.referenceSource === "upload" ? "source-button selected" : "source-button"}
          onClick={() => chooseSource("upload")}
        >
          <UploadSimple size={21} aria-hidden="true" />
          自定义参考
        </button>
      </fieldset>

      <StateNotice
        mode={
          state.referenceSource === "preset" && state.mode === "original_replication"
            ? "fixture"
            : "live"
        }
      >
        {state.referenceSource === "preset" && state.mode === "original_replication"
          ? "确定性演示数据；不会调用付费模型，也不伪造实拍照片。"
          : "媒体会在你明确同意后发送至火山方舟分析。"}
      </StateNotice>

      <button
        type="button"
        className="primary-button"
        onClick={() => {
          dispatch({
            type: "patch",
            value: {
              sessionId: null,
              executionMode: null,
              caseId: state.referenceSource === "preset" ? state.caseId : null,
            },
          });
          navigate("/reference");
        }}
      >
        选择参考画面 <ArrowRight size={20} aria-hidden="true" />
      </button>
    </section>
  );
}

export function ReferenceScreen() {
  const navigate = useNavigate();
  const { state, dispatch } = useFlow();
  const selected = useMemo(() => findTestImageCase(state.caseId), [state.caseId]);
  const initialBox = selected?.referenceAsset.selected_box ?? {
    x: 0.25,
    y: 0.12,
    width: 0.5,
    height: 0.76,
  };
  const preview =
    state.referenceSource === "preset" ? selected?.publicAssets.detail : state.referenceMedia?.previewUrl;
  const dimensions =
    state.referenceSource === "preset"
      ? selected === null
        ? null
        : { width: selected.referenceAsset.width, height: selected.referenceAsset.height }
      : state.referenceMedia === null
        ? null
        : { width: state.referenceMedia.width, height: state.referenceMedia.height };

  return (
    <section className="page reference-page">
      <PageHeader title="选择并圈出人物" backTo="/" />
      {state.referenceSource === "preset" ? (
        <>
          <div className="section-heading">
            <span>
              <strong>4 个公开预设</strong>
              <small>全部经过真实圈选页，不直接跳过</small>
            </span>
          </div>
          <div className="preset-grid">
            {testImageDataset.cases.map((item) => (
              <PresetCard
                key={item.caseId}
                item={item}
                onClick={() => {
                  dispatch({
                    type: "patch",
                    value: {
                      caseId: item.caseId,
                      selectedBox: item.referenceAsset.selected_box,
                    },
                  });
                  analytics.track("reference_select", { case_id: item.caseId, source: "preset" });
                }}
              />
            ))}
          </div>
        </>
      ) : (
        <MediaPicker
          value={state.referenceMedia}
          title="上传自己的参考图片或短视频"
          onChange={(referenceMedia) => {
            dispatch({
              type: "patch",
              value: {
                referenceMedia,
                selectedBox: { x: 0.25, y: 0.12, width: 0.5, height: 0.76 },
              },
            });
            analytics.track("reference_upload", { source: "upload" });
          }}
        />
      )}

      {preview !== undefined && dimensions !== null ? (
        <>
          <h2 className="subheading">圈出需要复刻的人物</h2>
          <SelectionEditor
            src={preview}
            width={dimensions.width}
            height={dimensions.height}
            value={state.selectedBox}
            initialValue={initialBox}
            onChange={(selectedBox) => dispatch({ type: "patch", value: { selectedBox } })}
          />
        </>
      ) : (
        <div className="empty-card">
          <ImageSquare size={30} aria-hidden="true" />
          <strong>{state.referenceSource === "preset" ? "先选择一个预设" : "先添加参考画面"}</strong>
          <small>完成后会在这里进行人物圈选。</small>
        </div>
      )}

      <button
        type="button"
        className="primary-button"
        disabled={preview === undefined || dimensions === null}
        onClick={() => {
          analytics.track("circle_complete", { source: state.referenceSource });
          navigate("/constraints");
        }}
      >
        确认圈选 <ArrowRight size={20} aria-hidden="true" />
      </button>
    </section>
  );
}

function ChoiceRow({
  icon,
  title,
  description,
  value,
  onChange,
}: {
  icon: React.ReactNode;
  title: string;
  description: string;
  value: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <div className="choice-row">
      <span className="choice-copy">
        {icon}
        <span>
          <strong>{title}</strong>
          <small>{description}</small>
        </span>
      </span>
      <span className="segmented" role="group" aria-label={title}>
        <button type="button" className={value ? "selected" : ""} onClick={() => onChange(true)}>
          是
        </button>
        <button type="button" className={!value ? "selected" : ""} onClick={() => onChange(false)}>
          否
        </button>
      </span>
    </div>
  );
}

function ErrorCard({ error, onRetry }: { error: SoloShotApiError; onRetry: () => void }) {
  return (
    <div className="error-card" role="alert">
      <Warning size={22} weight="fill" aria-hidden="true" />
      <span>
        <strong>{error.message}</strong>
        <small>{error.code} · 未切换到 Fixture</small>
      </span>
      {error.recoverable ? (
        <button type="button" onClick={onRetry}>
          <Repeat size={17} aria-hidden="true" /> 重试
        </button>
      ) : null}
    </div>
  );
}

export function ConstraintsScreen() {
  const navigate = useNavigate();
  const { state, dispatch } = useFlow();
  const selected = findTestImageCase(state.caseId);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<SoloShotApiError | null>(null);
  const [controller, setController] = useState<AbortController | null>(null);
  const isLive = state.referenceSource === "upload" || state.mode === "scene_adaptation";

  function updateConstraints(value: Partial<UserConstraints>): void {
    dispatch({ type: "patch", value: { constraints: { ...state.constraints, ...value } } });
  }

  async function submit(): Promise<void> {
    if (isLive && !state.consent) {
      setError(
        new SoloShotApiError(
          "Live 流程需要先同意媒体发送至火山方舟分析。",
          "CONSENT_REQUIRED",
          true,
        ),
      );
      return;
    }
    if (state.referenceSource === "preset" && selected === null) {
      navigate("/reference");
      return;
    }
    if (state.referenceSource === "upload" && state.referenceMedia === null) {
      setError(new SoloShotApiError("本地文件无法在刷新后恢复，请重新选择。", "MEDIA_NOT_READY", true));
      return;
    }
    const abortController = new AbortController();
    setController(abortController);
    setBusy(true);
    setError(null);
    setProgress(2);
    try {
      let sessionId = state.sessionId;
      if (sessionId === null) {
        const session = await soloShotApi.createSession({
          constraints: state.constraints,
          mode: state.mode,
          referenceSource: state.referenceSource,
          consent: state.consent,
        });
        sessionId = session.data.session_id;
        dispatch({ type: "patch", value: { sessionId } });
        setProgress(12);
      }

      let referenceAsset: ReferenceAsset;
      if (state.referenceSource === "preset" && selected !== null) {
        referenceAsset = { ...selected.referenceAsset, selected_box: state.selectedBox };
      } else if (state.referenceMedia !== null) {
        const media = await soloShotApi.uploadMedia(
          sessionId,
          "reference",
          state.referenceMedia.blob,
          {
            signal: abortController.signal,
            onProgress: (value) => setProgress(Math.round(12 + value * 0.58)),
          },
        );
        referenceAsset = {
          schema_version: "1.0",
          reference_id: `ref_${crypto.randomUUID().replaceAll("-", "")}`,
          media_asset_id: media.media_asset_id,
          media_type: state.referenceMedia.mediaType,
          source_type: "upload",
          width: state.referenceMedia.width,
          height: state.referenceMedia.height,
          selected_box: state.selectedBox,
          attribution: {
            source_label: "用户在 H5 明确选择的本地媒体",
            creator_label: null,
          },
        };
      } else {
        throw new SoloShotApiError("参考画面不可用，请重新选择。", "MEDIA_NOT_READY", true);
      }

      const analyzed = await soloShotApi.analyzeReference(sessionId, referenceAsset);
      setProgress(100);
      dispatch({
        type: "patch",
        value: { executionMode: analyzed.executionMode ?? (isLive ? "live" : "fixture") },
      });
      analytics.track(
        "agent_success",
        {
          mode: state.mode,
          source: state.referenceSource,
          execution_mode: analyzed.executionMode ?? (isLive ? "live" : "fixture"),
        },
        sessionId,
      );
      await analytics.flush(sessionId);
      navigate(`/session/${sessionId}/analysis`);
    } catch (caught) {
      const apiError =
        caught instanceof SoloShotApiError
          ? caught
          : new SoloShotApiError("无法完成参考分析，请重试。", "INTERNAL_ERROR", true);
      dispatch({ type: "patch", value: { executionMode: "error" } });
      setError(apiError);
      analytics.track("agent_fail", { error_code: apiError.code, mode: state.mode }, state.sessionId);
    } finally {
      setBusy(false);
      setController(null);
    }
  }

  return (
    <section className="page constraints-page">
      <PageHeader title="拍摄条件" backTo="/reference" />
      <div className="choice-panel">
        <ChoiceRow
          icon={<User size={20} aria-hidden="true" />}
          title="独自旅行"
          description="按单人可执行方式规划"
          value={state.constraints.solo_traveler}
          onChange={(solo_traveler) => updateConstraints({ solo_traveler })}
        />
        <ChoiceRow
          icon={<Camera size={20} aria-hidden="true" />}
          title="有三脚架"
          description="没有也会给出稳定支撑方案"
          value={state.constraints.tripod_available}
          onChange={(tripod_available) => updateConstraints({ tripod_available })}
        />
        <ChoiceRow
          icon={<Suitcase size={20} aria-hidden="true" />}
          title="携带行李"
          description="避免复杂移动与危险动作"
          value={state.constraints.has_luggage}
          onChange={(has_luggage) => updateConstraints({ has_luggage })}
        />
      </div>

      <label className="text-field">
        其他备注
        <input
          value={state.constraints.notes ?? ""}
          maxLength={120}
          placeholder="例如：时间紧、脚下有台阶"
          onChange={(event) => updateConstraints({ notes: event.target.value || null })}
        />
      </label>

      {isLive ? (
        <label className="consent-card">
          <input
            type="checkbox"
            checked={state.consent}
            onChange={(event) => dispatch({ type: "patch", value: { consent: event.target.checked } })}
          />
          <span>
            <strong>我同意媒体发送至火山方舟分析</strong>
            <small>未同意时服务端不会创建媒体上传；临时媒体默认保留 24 小时。</small>
          </span>
        </label>
      ) : (
        <StateNotice mode="fixture">预设原图复刻使用确定性 Fixture，无外部 AI 媒体调用。</StateNotice>
      )}

      {busy ? <UploadProgress value={progress} onCancel={() => controller?.abort()} /> : null}
      {error !== null ? <ErrorCard error={error} onRetry={() => void submit()} /> : null}

      <button type="button" className="primary-button" disabled={busy} onClick={() => void submit()}>
        {busy ? "正在准备任务…" : "开始参考分析"} <ArrowRight size={20} aria-hidden="true" />
      </button>
    </section>
  );
}
