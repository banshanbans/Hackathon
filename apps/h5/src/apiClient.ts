import type { components } from "./generated/api";
import { sha256 } from "./media/processing";

// openapi-typescript currently exposes a root JSON Schema `$defs` block as if it
// were response data for external Draft 2020-12 schemas. Runtime payloads never
// contain that metadata, so remove it recursively at the generated-client edge.
type ContractData<T> = T extends readonly (infer Item)[]
  ? ContractData<Item>[]
  : T extends object
    ? { [Key in keyof T as Key extends "$defs" ? never : Key]: ContractData<T[Key]> }
    : T;

export type SoloShotSession = ContractData<components["schemas"]["SoloShotSession"]>;
export type ReferenceAnalysis = ContractData<components["schemas"]["ReferenceAnalysis"]>;
export type AgentRun = ContractData<components["schemas"]["AgentRun"]>;
export type Capture = ContractData<components["schemas"]["Capture"]>;
export type ResultEvaluation = ContractData<components["schemas"]["ResultEvaluation"]>;
export type ShotPlan = ContractData<components["schemas"]["ShotPlan"]>;
export type UserConstraints = ContractData<components["schemas"]["UserConstraints"]>;
export type ReferenceAsset = ContractData<components["schemas"]["ReferenceAsset"]>;
export type MediaAsset = ContractData<components["schemas"]["MediaAsset"]>;
export type MediaPurpose = ContractData<components["schemas"]["MediaPurpose"]>;
export type MediaUploadTicket = ContractData<components["schemas"]["MediaUploadTicket"]>;
export type MediaAccess = ContractData<components["schemas"]["MediaAccess"]>;
export type AnalyticsEvent = ContractData<components["schemas"]["AnalyticsEvent"]>;
export type EventBatchReceipt = ContractData<components["schemas"]["EventBatchReceipt"]>;
export type HandoffTask = ContractData<components["schemas"]["HandoffTask"]>;
export type HandoffCreateResult = ContractData<components["schemas"]["HandoffCreateResult"]>;
export type HandoffClaimResult = ContractData<components["schemas"]["HandoffClaimResult"]>;
export type CaptureConsentReceipt = ContractData<components["schemas"]["CaptureConsentReceipt"]>;

export type ExecutionMode = "fixture" | "mock" | "live" | "cache" | "fallback" | "error";

type ApiEnvelope<T> = {
  data: T;
  executionMode: ExecutionMode | null;
  requestId: string | null;
};

type UnknownRecord = Record<string, unknown>;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasString(value: UnknownRecord, key: string): boolean {
  return typeof value[key] === "string";
}

function isSession(value: unknown): value is SoloShotSession {
  return isRecord(value) && hasString(value, "session_id") && hasString(value, "state");
}

function isReferenceAnalysis(value: unknown): value is ReferenceAnalysis {
  return (
    isRecord(value) &&
    hasString(value, "analysis_id") &&
    hasString(value, "reference_id") &&
    typeof value.person_count === "number"
  );
}

function isAgentRun(value: unknown): value is AgentRun {
  return isRecord(value) && hasString(value, "run_id") && Array.isArray(value.selected_skills);
}

function isCapture(value: unknown): value is Capture {
  return isRecord(value) && hasString(value, "capture_id") && typeof value.round_index === "number";
}

function isEvaluation(value: unknown): value is ResultEvaluation {
  return (
    isRecord(value) &&
    hasString(value, "evaluation_id") &&
    typeof value.needs_retake === "boolean" &&
    typeof value.goal_satisfied === "boolean"
  );
}

function isMediaAsset(value: unknown): value is MediaAsset {
  return isRecord(value) && hasString(value, "media_asset_id") && hasString(value, "status");
}

function isUploadTicket(value: unknown): value is MediaUploadTicket {
  return (
    isRecord(value) &&
    hasString(value, "upload_url") &&
    isMediaAsset(value.asset) &&
    isRecord(value.upload_headers)
  );
}

function isMediaAccess(value: unknown): value is MediaAccess {
  return isRecord(value) && hasString(value, "download_url") && isMediaAsset(value.asset);
}

function isEventReceipt(value: unknown): value is EventBatchReceipt {
  return (
    isRecord(value) &&
    typeof value.accepted_count === "number" &&
    typeof value.duplicate_count === "number"
  );
}

function isCaptureConsentReceipt(value: unknown): value is CaptureConsentReceipt {
  return (
    isRecord(value) &&
    hasString(value, "session_id") &&
    hasString(value, "capture_upload_consent_at")
  );
}

function isHandoffTask(value: unknown): value is HandoffTask {
  return (
    isRecord(value) &&
    hasString(value, "handoff_id") &&
    hasString(value, "code") &&
    hasString(value, "status") &&
    hasString(value, "expires_at") &&
    !Object.hasOwn(value, "session_id")
  );
}

function isHandoffCreateResult(value: unknown): value is HandoffCreateResult {
  return (
    isRecord(value) &&
    isHandoffTask(value.handoff) &&
    hasString(value, "management_token") &&
    hasString(value, "qr_payload")
  );
}

function isHandoffClaimResult(value: unknown): value is HandoffClaimResult {
  return (
    isRecord(value) &&
    isHandoffTask(value.handoff) &&
    isSession(value.session) &&
    hasString(value, "claim_token")
  );
}

export class SoloShotApiError extends Error {
  readonly code: string;
  readonly recoverable: boolean;

  constructor(message: string, code = "NETWORK_ERROR", recoverable = true) {
    super(message);
    this.name = "SoloShotApiError";
    this.code = code;
    this.recoverable = recoverable;
  }
}

export const apiBaseUrl =
  (import.meta.env.VITE_API_BASE_URL as string | undefined)?.replace(/\/$/, "") ??
  "http://localhost:8000";

function idempotencyKey(operation: string): string {
  const suffix =
    typeof crypto.randomUUID === "function"
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random()}`;
  return `h5-${operation}-${suffix}`.slice(0, 120);
}

async function request<T>(
  path: string,
  init: RequestInit,
  guard: (value: unknown) => value is T,
): Promise<ApiEnvelope<T>> {
  let response: Response;
  try {
    response = await fetch(`${apiBaseUrl}${path}`, init);
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new SoloShotApiError("上传已取消。", "UPLOAD_CANCELED", true);
    }
    throw new SoloShotApiError(
      "无法连接 SoloShot API，请确认本地服务已启动。",
      "NETWORK_ERROR",
      true,
    );
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new SoloShotApiError("服务返回了无法解析的响应。", "INVALID_JSON", true);
  }

  if (!response.ok) {
    const error = isRecord(payload) && isRecord(payload.error) ? payload.error : null;
    throw new SoloShotApiError(
      error !== null && typeof error.message === "string"
        ? error.message
        : "请求未完成，请稍后重试。",
      error !== null && typeof error.code === "string" ? error.code : "REQUEST_FAILED",
      error !== null && typeof error.recoverable === "boolean"
        ? error.recoverable
        : response.status >= 500,
    );
  }

  if (!isRecord(payload) || !guard(payload.data)) {
    throw new SoloShotApiError("服务响应与当前契约不一致。", "INVALID_JSON", false);
  }
  const mode = response.headers.get("X-SoloShot-Execution-Mode");
  return {
    data: payload.data,
    executionMode:
      mode === "fixture" ||
      mode === "mock" ||
      mode === "live" ||
      mode === "cache" ||
      mode === "fallback"
        ? mode
        : null,
    requestId: response.headers.get("X-Request-ID"),
  };
}

function jsonRequest(
  operation: string,
  body: unknown,
  signal?: AbortSignal,
  stableIdempotencyKey?: string,
): RequestInit {
  const init: RequestInit = {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Idempotency-Key": stableIdempotencyKey ?? idempotencyKey(operation),
    },
    body: JSON.stringify(body),
  };
  if (signal !== undefined) {
    init.signal = signal;
  }
  return init;
}

export const soloShotApi = {
  createSession(input: {
    constraints: UserConstraints;
    mode: "original_replication" | "scene_adaptation";
    referenceSource: "preset" | "upload";
    consent: boolean;
  }): Promise<ApiEnvelope<SoloShotSession>> {
    return request(
      "/api/v1/sessions",
      jsonRequest("session", {
        schema_version: "1.0",
        source_channel: input.referenceSource === "preset" ? "demo_preset" : "h5_direct",
        mode: input.mode,
        user_constraints: input.constraints,
        external_ai_consent: input.consent,
      }),
      isSession,
    );
  },

  analyzeReference(
    sessionId: string,
    referenceAsset: ReferenceAsset,
  ): Promise<ApiEnvelope<ReferenceAnalysis>> {
    return request(
      "/api/v1/references/analyze",
      jsonRequest("reference", {
        schema_version: "1.0",
        session_id: sessionId,
        reference_asset: referenceAsset,
      }),
      isReferenceAnalysis,
    );
  },

  adaptReference(
    sessionId: string,
    referenceId: string,
    sceneAssetId: string,
    stableIdempotencyKey?: string,
    signal?: AbortSignal,
  ): Promise<ApiEnvelope<ReferenceAnalysis>> {
    return request(
      "/api/v1/references/adapt",
      jsonRequest(
        "adapt",
        {
          schema_version: "1.0",
          session_id: sessionId,
          reference_id: referenceId,
          scene_asset_id: sceneAssetId,
        },
        signal,
        stableIdempotencyKey,
      ),
      isReferenceAnalysis,
    );
  },

  createAgentRun(
    sessionId: string,
    intent: "original_replication" | "scene_adaptation",
    stableIdempotencyKey?: string,
    signal?: AbortSignal,
  ): Promise<ApiEnvelope<AgentRun>> {
    return request(
      "/api/v1/agent/runs",
      jsonRequest(
        "agent",
        {
          schema_version: "1.0",
          session_id: sessionId,
          intent,
        },
        signal,
        stableIdempotencyKey,
      ),
      isAgentRun,
    );
  },

  getSession(sessionId: string): Promise<ApiEnvelope<SoloShotSession>> {
    return request(
      `/api/v1/sessions/${encodeURIComponent(sessionId)}`,
      { method: "GET" },
      isSession,
    );
  },

  recordCaptureConsent(
    sessionId: string,
    externalAiConsent: boolean,
    stableIdempotencyKey?: string,
  ): Promise<ApiEnvelope<CaptureConsentReceipt>> {
    return request(
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/capture-consent`,
      jsonRequest(
        "capture-consent",
        {
          schema_version: "1.0",
          capture_upload_consent: true,
          external_ai_consent: externalAiConsent,
        },
        undefined,
        stableIdempotencyKey,
      ),
      isCaptureConsentReceipt,
    );
  },

  createHandoff(
    sessionId: string,
    stableIdempotencyKey: string,
  ): Promise<ApiEnvelope<HandoffCreateResult>> {
    return request(
      "/api/v1/handoffs",
      jsonRequest(
        "handoff-create",
        { schema_version: "1.0", session_id: sessionId },
        undefined,
        stableIdempotencyKey,
      ),
      isHandoffCreateResult,
    );
  },

  getHandoff(code: string): Promise<ApiEnvelope<HandoffTask>> {
    return request(
      `/api/v1/handoffs/${encodeURIComponent(code.toUpperCase())}`,
      { method: "GET" },
      isHandoffTask,
    );
  },

  revokeHandoff(
    code: string,
    managementToken: string,
    stableIdempotencyKey: string,
  ): Promise<ApiEnvelope<HandoffTask>> {
    return request(
      `/api/v1/handoffs/${encodeURIComponent(code.toUpperCase())}`,
      {
        method: "DELETE",
        headers: {
          "Idempotency-Key": stableIdempotencyKey,
          "X-Handoff-Management-Token": managementToken,
        },
      },
      isHandoffTask,
    );
  },

  claimHandoff(
    code: string,
    clientInstanceId: string,
    stableIdempotencyKey: string,
  ): Promise<ApiEnvelope<HandoffClaimResult>> {
    return request(
      `/api/v1/handoffs/${encodeURIComponent(code.toUpperCase())}/claim`,
      jsonRequest(
        "handoff-claim",
        { schema_version: "1.0", client_instance_id: clientInstanceId },
        undefined,
        stableIdempotencyKey,
      ),
      isHandoffClaimResult,
    );
  },

  createMediaUpload(
    sessionId: string,
    purpose: MediaPurpose,
    blob: Blob,
    digest: string,
    signal?: AbortSignal,
    stableIdempotencyKey?: string,
  ): Promise<ApiEnvelope<MediaUploadTicket>> {
    return request(
      "/api/v1/media/uploads",
      jsonRequest(
        `media-${purpose}`,
        {
          schema_version: "1.0",
          session_id: sessionId,
          purpose,
          content_type: "image/jpeg",
          byte_size: blob.size,
          sha256: digest,
        },
        signal,
        stableIdempotencyKey,
      ),
      isUploadTicket,
    );
  },

  completeMediaUpload(
    sessionId: string,
    mediaAssetId: string,
    signal?: AbortSignal,
    stableIdempotencyKey?: string,
  ): Promise<ApiEnvelope<MediaAsset>> {
    return request(
      `/api/v1/media/uploads/${encodeURIComponent(mediaAssetId)}/complete`,
      jsonRequest(
        "media-complete",
        { schema_version: "1.0", session_id: sessionId },
        signal,
        stableIdempotencyKey,
      ),
      isMediaAsset,
    );
  },

  async uploadMedia(
    sessionId: string,
    purpose: MediaPurpose,
    blob: Blob,
    options: {
      signal?: AbortSignal;
      onProgress?: (value: number) => void;
      createIdempotencyKey?: string;
      completeIdempotencyKey?: string;
    } = {},
  ): Promise<MediaAsset> {
    options.onProgress?.(5);
    const digest = await sha256(blob);
    options.onProgress?.(15);
    const ticket = await this.createMediaUpload(
      sessionId,
      purpose,
      blob,
      digest,
      options.signal,
      options.createIdempotencyKey,
    );
    options.onProgress?.(35);
    let uploadResponse: Response;
    try {
      const uploadInit: RequestInit = {
        method: "PUT",
        headers: ticket.data.upload_headers,
        body: blob,
      };
      if (options.signal !== undefined) {
        uploadInit.signal = options.signal;
      }
      uploadResponse = await fetch(ticket.data.upload_url, uploadInit);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") {
        throw new SoloShotApiError("上传已取消。", "UPLOAD_CANCELED", true);
      }
      throw new SoloShotApiError("媒体上传失败，请重试。", "CAPTURE_UPLOAD_FAILED", true);
    }
    if (!uploadResponse.ok) {
      throw new SoloShotApiError("媒体上传失败，请重试。", "CAPTURE_UPLOAD_FAILED", true);
    }
    options.onProgress?.(80);
    const completed = await this.completeMediaUpload(
      sessionId,
      ticket.data.asset.media_asset_id,
      options.signal,
      options.completeIdempotencyKey,
    );
    options.onProgress?.(100);
    return completed.data;
  },

  getMediaAccess(sessionId: string, mediaAssetId: string): Promise<ApiEnvelope<MediaAccess>> {
    const query = new URLSearchParams({ session_id: sessionId });
    return request(
      `/api/v1/media/${encodeURIComponent(mediaAssetId)}/access?${query.toString()}`,
      { method: "GET" },
      isMediaAccess,
    );
  },

  createCapture(
    sessionId: string,
    mediaAssetId: string,
    roundIndex: 1 | 2,
    options: {
      captureMethod?: "photo" | "short_video" | "photo_fallback";
      frameSelection?: {
        frameId: string;
        timestampMs: number | null;
        selectionSource: "local_recommended" | "user_selected";
      };
      stableIdempotencyKey?: string;
    } = {},
  ): Promise<ApiEnvelope<Capture>> {
    return request(
      "/api/v1/captures",
      jsonRequest(
        `capture-${roundIndex}`,
        {
          schema_version: "1.0",
          session_id: sessionId,
          round_index: roundIndex,
          media_asset_id: mediaAssetId,
          ...(options.captureMethod === undefined
            ? {}
            : { capture_method: options.captureMethod }),
          ...(options.frameSelection === undefined
            ? {}
            : {
                frame_selection: {
                  frame_id: options.frameSelection.frameId,
                  timestamp_ms: options.frameSelection.timestampMs,
                  selection_source: options.frameSelection.selectionSource,
                },
              }),
        },
        undefined,
        options.stableIdempotencyKey,
      ),
      isCapture,
    );
  },

  createFixtureCapture(
    sessionId: string,
    caseId: string,
    roundIndex: 1 | 2,
  ): Promise<ApiEnvelope<Capture>> {
    return this.createCapture(sessionId, `media_fixture_${caseId}_round_${roundIndex}`, roundIndex);
  },

  createEvaluation(
    sessionId: string,
    captureId: string,
    stableIdempotencyKey?: string,
  ): Promise<ApiEnvelope<ResultEvaluation>> {
    return request(
      "/api/v1/evaluations",
      jsonRequest(
        "evaluation",
        {
          schema_version: "1.0",
          session_id: sessionId,
          capture_id: captureId,
        },
        undefined,
        stableIdempotencyKey,
      ),
      isEvaluation,
    );
  },

  sendEvents(events: AnalyticsEvent[]): Promise<ApiEnvelope<EventBatchReceipt>> {
    return request(
      "/api/v1/events/batch",
      jsonRequest("events", { schema_version: "1.0", events }),
      isEventReceipt,
    );
  },
};
