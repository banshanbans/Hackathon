export type HandoffDraft = {
  sessionId: string;
  createIdempotencyKey: string;
  code?: string;
  managementToken?: string;
  qrPayload?: string;
};

const storagePrefix = "soloshot:handoff:v1:";

function newKey(operation: string): string {
  const suffix =
    typeof crypto.randomUUID === "function"
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return `h5-${operation}-${suffix}`.slice(0, 120);
}

function storage(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

export function loadHandoffDraft(sessionId: string): HandoffDraft | null {
  const raw = storage()?.getItem(`${storagePrefix}${sessionId}`);
  if (raw === null || raw === undefined) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as Partial<HandoffDraft>;
    if (
      parsed.sessionId !== sessionId ||
      typeof parsed.createIdempotencyKey !== "string" ||
      (parsed.code !== undefined && typeof parsed.code !== "string") ||
      (parsed.managementToken !== undefined && typeof parsed.managementToken !== "string") ||
      (parsed.qrPayload !== undefined && typeof parsed.qrPayload !== "string")
    ) {
      return null;
    }
    return parsed as HandoffDraft;
  } catch {
    return null;
  }
}

export function createHandoffDraft(sessionId: string): HandoffDraft {
  const draft = { sessionId, createIdempotencyKey: newKey("handoff-create") };
  saveHandoffDraft(draft);
  return draft;
}

export function ensureHandoffDraft(sessionId: string): HandoffDraft {
  return loadHandoffDraft(sessionId) ?? createHandoffDraft(sessionId);
}

export function saveHandoffDraft(draft: HandoffDraft): void {
  storage()?.setItem(`${storagePrefix}${draft.sessionId}`, JSON.stringify(draft));
}

export function revokeIdempotencyKey(): string {
  return newKey("handoff-revoke");
}
