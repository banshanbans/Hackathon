import {
  ArrowSquareOut,
  CheckCircle,
  ClockCountdown,
  Copy,
  DeviceMobile,
  QrCode,
  Repeat,
  Trash,
  Warning,
} from "@phosphor-icons/react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { SoloShotApiError, soloShotApi, type HandoffTask } from "../apiClient";
import { analytics } from "../analytics";
import { PageHeader } from "../components/AppChrome";
import { HandoffQr } from "../components/HandoffQr";
import {
  createHandoffDraft,
  ensureHandoffDraft,
  revokeIdempotencyKey,
  saveHandoffDraft,
  type HandoffDraft,
} from "../handoff/storage";
import { creationModeLabels, productErrorCopy, roundLabel } from "../productCopy";

const handoffCodePattern = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/;

function messageForStatus(status: HandoffTask["status"]): string {
  switch (status) {
    case "created":
      return "等待 iPhone 接力";
    case "claimed":
      return "正在同步到 iPhone";
    case "completed":
      return "iPhone 已就绪";
    case "revoked":
      return "接力已取消";
    case "expired":
      return "任务码已过期";
  }
}

function remainingLabel(expiresAt: string, now: number): string {
  const seconds = Math.max(0, Math.ceil((Date.parse(expiresAt) - now) / 1000));
  const minutes = Math.floor(seconds / 60);
  return `${String(minutes).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

function ErrorPanel({
  error,
  retry,
  forceRetry = false,
  retryLabel = "再试一次",
}: {
  error: unknown;
  retry: () => void;
  forceRetry?: boolean;
  retryLabel?: string;
}) {
  const apiError =
    error instanceof SoloShotApiError
      ? error
      : new SoloShotApiError("任务码暂时不可用。", "REQUEST_FAILED", true);
  const copy = productErrorCopy(apiError.code);
  return (
    <div className="handoff-error" role="alert">
      <Warning size={28} weight="fill" aria-hidden="true" />
      <span>
        <strong>{copy.title}</strong>
        <small>{copy.detail}</small>
      </span>
      {apiError.recoverable || forceRetry ? (
        <button type="button" onClick={retry}>
          <Repeat size={18} aria-hidden="true" /> {retryLabel}
        </button>
      ) : null}
    </div>
  );
}

export function HandoffScreen() {
  const { id: sessionId = "" } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [draft, setDraft] = useState<HandoffDraft>(() => ensureHandoffDraft(sessionId));
  const [now, setNow] = useState(() => Date.now());
  const [notice, setNotice] = useState<string | null>(null);
  const [actionError, setActionError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);

  const createQuery = useQuery({
    queryKey: ["handoff-create", sessionId, draft.createIdempotencyKey],
    queryFn: () => soloShotApi.createHandoff(sessionId, draft.createIdempotencyKey),
    enabled: sessionId.startsWith("ss_") && draft.code === undefined,
    retry: 1,
  });

  useEffect(() => {
    const created = createQuery.data?.data;
    if (created === undefined || draft.code === created.handoff.code) {
      return;
    }
    const next: HandoffDraft = {
      ...draft,
      code: created.handoff.code,
      managementToken: created.management_token,
      qrPayload: created.qr_payload,
    };
    saveHandoffDraft(next);
    setDraft(next);
    analytics.track("handoff_qr_create", { mode: created.handoff.mode }, sessionId);
    void analytics.flush(sessionId);
  }, [createQuery.data, draft, sessionId]);

  const statusQuery = useQuery({
    queryKey: ["handoff", draft.code],
    queryFn: () => soloShotApi.getHandoff(draft.code ?? ""),
    enabled: draft.code !== undefined,
    refetchInterval: (query) => {
      const status = (query.state.data?.data as HandoffTask | undefined)?.status;
      return status === "created" || status === "claimed" ? 2_000 : false;
    },
    retry: 1,
  });

  const sessionQuery = useQuery({
    queryKey: ["session", sessionId, "handoff-progress"],
    queryFn: () => soloShotApi.getSession(sessionId),
    enabled: statusQuery.data?.data.status === "completed",
    refetchInterval: (query) => {
      const session = query.state.data?.data;
      return session?.state === "completed" ? false : 2_000;
    },
    retry: 1,
  });

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, []);

  const handoff = statusQuery.data?.data ?? createQuery.data?.data.handoff;
  const requestError = createQuery.error ?? statusQuery.error;
  const qrPayload = draft.qrPayload ?? createQuery.data?.data.qr_payload;

  async function copyCode(): Promise<void> {
    if (handoff === undefined) {
      return;
    }
    try {
      await navigator.clipboard.writeText(handoff.code);
      setNotice("任务码已复制");
    } catch {
      setNotice("无法自动复制，请长按任务码");
    }
  }

  async function revoke(regenerate: boolean): Promise<void> {
    if (handoff === undefined || draft.managementToken === undefined) {
      setActionError(new SoloShotApiError("管理凭据无法恢复，请刷新后重试。", "INVALID_STATE", true));
      return;
    }
    setBusy(true);
    setActionError(null);
    try {
      await soloShotApi.revokeHandoff(
        handoff.code,
        draft.managementToken,
        revokeIdempotencyKey(),
      );
      await queryClient.invalidateQueries({ queryKey: ["session", sessionId] });
      if (regenerate) {
        const next = createHandoffDraft(sessionId);
        setDraft(next);
      } else {
        navigate(`/session/${sessionId}/plan`);
      }
    } catch (error) {
      setActionError(error);
    } finally {
      setBusy(false);
    }
  }

  function regenerate(): void {
    setActionError(null);
    setNotice(null);
    setDraft(createHandoffDraft(sessionId));
  }

  if (requestError !== null) {
    const gone =
      requestError instanceof SoloShotApiError &&
      (requestError.code === "HANDOFF_EXPIRED" || requestError.code === "HANDOFF_REVOKED");
    return (
      <section className="page handoff-page">
        <PageHeader title="用 iPhone，继续这次创作" backTo={`/session/${sessionId}/plan`} />
        <ErrorPanel
          error={requestError}
          forceRetry={gone}
          retryLabel={gone ? "重新生成任务码" : "再试一次"}
          retry={() => {
            if (gone) {
              regenerate();
            } else {
              void createQuery.refetch();
              void statusQuery.refetch();
            }
          }}
        />
      </section>
    );
  }

  return (
    <section className="page handoff-page">
      <PageHeader title="用 iPhone，继续这次创作" backTo={`/session/${sessionId}/plan`} />
      <div className="handoff-heading">
        <DeviceMobile size={30} weight="duotone" aria-hidden="true" />
        <span>
          <p>扫描后，机位、动作与安全提醒会完整接力。</p>
        </span>
      </div>
      {handoff === undefined || qrPayload === undefined ? (
        <div className="handoff-loading" role="status">正在准备任务码…</div>
      ) : (
        <>
          <HandoffQr payload={qrPayload} />
          <div className="handoff-code" aria-label={`任务码 ${handoff.code}`}>
            {handoff.code.split("").map((character, index) => (
              <span key={`${character}-${index}`}>{character}</span>
            ))}
          </div>
          <div className="handoff-timer" role="timer">
            <ClockCountdown size={20} aria-hidden="true" />
            <span>剩余时间</span>
            <strong>{remainingLabel(handoff.expires_at, now)}</strong>
          </div>
          <div className="state-notice" role="status">
            {messageForStatus(handoff.status)}
          </div>
          {notice !== null ? <p className="handoff-notice" role="status">{notice}</p> : null}
          {actionError !== null ? <ErrorPanel error={actionError} retry={() => void revoke(false)} /> : null}
          {handoff.status === "created" ? (
            <div className="handoff-actions">
              <button type="button" className="secondary-button" onClick={() => void copyCode()}>
                <Copy size={19} aria-hidden="true" /> 复制任务码
              </button>
              <button type="button" className="danger-button" disabled={busy} onClick={() => void revoke(false)}>
                <Trash size={19} aria-hidden="true" /> 取消接力
              </button>
            </div>
          ) : null}
          {handoff.status === "claimed" ? (
            <button
              type="button"
              className="danger-button"
              disabled={busy}
              onClick={() => void revoke(false)}
            >
              <Trash size={19} aria-hidden="true" /> 取消接力并回到网页
            </button>
          ) : null}
          {handoff.status === "revoked" || handoff.status === "expired" ? (
            <button type="button" className="primary-button" disabled={busy} onClick={regenerate}>
              <Repeat size={20} aria-hidden="true" /> 重新生成任务码
            </button>
          ) : null}
          {handoff.status === "completed" ? (
            <div className="handoff-complete">
              <CheckCircle size={30} weight="fill" aria-hidden="true" />
              <strong>iPhone 已就绪</strong>
              <small>{sessionProgressLabel(sessionQuery.data?.data)}</small>
              {sessionQuery.data?.data.state === "completed" ? (
                <button
                  type="button"
                  className="primary-button"
                  onClick={() => navigate(`/session/${sessionId}/result`)}
                >
                  查看我的作品
                </button>
              ) : null}
            </div>
          ) : null}
        </>
      )}
      <button type="button" className="text-button" onClick={() => navigate(`/session/${sessionId}/plan`)}>
        返回 ShotPlan
      </button>
    </section>
  );
}

function sessionProgressLabel(session: Awaited<ReturnType<typeof soloShotApi.getSession>>["data"] | undefined): string {
  if (session === undefined || session.state === "handoff_ready") {
    return "等待 iPhone 开始现场陪拍。";
  }
  if (session.state === "evaluating") {
    return `正在复盘${roundLabel(session.capture_rounds.length)}成片。`;
  }
  if (session.state === "capturing") {
    return `iPhone 已完成${roundLabel(session.capture_rounds.length)}拍摄。`;
  }
  if (session.state === "coaching") {
    return "第一次建议已生成，iPhone 正在准备调整后的拍摄。";
  }
  if (session.state === "completed") {
    return "iPhone 已完成本次拍摄任务。";
  }
  return "iPhone 正在处理任务。";
}

export function HandoffLandingScreen() {
  const { code: rawCode = "" } = useParams<{ code: string }>();
  const code = useMemo(() => rawCode.toUpperCase(), [rawCode]);
  const valid = handoffCodePattern.test(code);
  const query = useQuery({
    queryKey: ["handoff-public", code],
    queryFn: () => soloShotApi.getHandoff(code),
    enabled: valid,
    retry: 1,
  });

  return (
    <section className="page handoff-landing-page">
      <PageHeader title="这份 ShotPlan，已在等你" backTo="/" />
      <div className="handoff-heading">
        <QrCode size={30} weight="duotone" aria-hidden="true" />
        <span>
          <p>打开 SoloShot，把网页里的灵感带到现场。</p>
        </span>
      </div>
      {!valid ? (
        <ErrorPanel
          error={new SoloShotApiError("任务码格式无效。", "VALIDATION_ERROR", false)}
          retry={() => undefined}
        />
      ) : query.error !== null ? (
        <ErrorPanel error={query.error} retry={() => void query.refetch()} />
      ) : query.data === undefined ? (
        <div className="handoff-loading" role="status">正在确认这份 ShotPlan…</div>
      ) : (
        <>
          <div className="landing-preview">
            <span>
              <small>任务码</small>
              <strong>{query.data.data.code}</strong>
            </span>
            <span>
              <small>创作方式</small>
              <strong>{creationModeLabels[query.data.data.mode]}</strong>
            </span>
            <span>
              <small>状态</small>
              <strong>{messageForStatus(query.data.data.status)}</strong>
            </span>
          </div>
          <button
            type="button"
            className="primary-button"
            disabled={query.data.data.status !== "created"}
            onClick={() => {
              window.location.assign(`soloshot://handoff/${code}`);
            }}
          >
            在 SoloShot 中继续 <ArrowSquareOut size={20} aria-hidden="true" />
          </button>
          <p className="handoff-notice">暂时没安装 App？在 iPhone 输入六位任务码即可继续。</p>
        </>
      )}
    </section>
  );
}
