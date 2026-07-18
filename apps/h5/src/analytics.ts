import { soloShotApi, type AnalyticsEvent } from "./apiClient";

type EventName = AnalyticsEvent["event_name"];
type SafeProperties = Record<string, string | number | boolean>;
type PendingEvent = Omit<AnalyticsEvent, "session_id"> & { session_id: string | null };

const STORAGE_KEY = "soloshot.w2.analytics";
const ALLOWED_PROPERTIES = new Set([
  "mode",
  "source",
  "case_id",
  "execution_mode",
  "latency_ms",
  "round_index",
  "route",
  "reference_source",
  "status",
  "error_code",
]);

function readQueue(): PendingEvent[] {
  try {
    const value = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? "[]") as unknown;
    return Array.isArray(value) ? (value as PendingEvent[]) : [];
  } catch {
    return [];
  }
}

function writeQueue(events: PendingEvent[]): void {
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(events.slice(-100)));
}

function safeProperties(properties: SafeProperties): SafeProperties {
  return Object.fromEntries(
    Object.entries(properties).filter(([key, value]) => {
      return ALLOWED_PROPERTIES.has(key) && ["string", "number", "boolean"].includes(typeof value);
    }),
  );
}

export const analytics = {
  track(
    eventName: EventName,
    properties: SafeProperties,
    sessionId: string | null = null,
  ): void {
    const queue = readQueue();
    const eventId =
      typeof crypto.randomUUID === "function"
        ? crypto.randomUUID()
        : "00000000-0000-4000-8000-000000000000";
    if (queue.some((item) => item.event_id === eventId)) {
      return;
    }
    queue.push({
      schema_version: "1.0",
      event_id: eventId,
      event_name: eventName,
      session_id: sessionId,
      source_channel: "h5_direct",
      client: "h5",
      timestamp: new Date().toISOString(),
      properties: safeProperties(properties),
    });
    writeQueue(queue);
  },

  async flush(sessionId: string): Promise<void> {
    const pending = readQueue();
    if (pending.length === 0) {
      return;
    }
    const events = pending.map((item) => ({ ...item, session_id: item.session_id ?? sessionId }));
    try {
      await soloShotApi.sendEvents(events);
      const sentIds = new Set(events.map((item) => item.event_id));
      writeQueue(readQueue().filter((item) => !sentIds.has(item.event_id)));
    } catch {
      // Keep the privacy-safe batch for the next in-session retry.
    }
  },
};
