import type { SilhouetteContour } from "../domain/silhouette";
import type {
  PoseRuntime,
  PreparedPoseRuntime,
  ReferenceSilhouetteResult,
} from "../pose/poseLandmarker";

type CachedRuntime = PreparedPoseRuntime & { expiresAt: number; timer: number };

const CACHE_PREFIX = "soloshot:reference-silhouette:1:";
const RUNTIME_TTL_MS = 60_000;
const runtimes = new Map<string, CachedRuntime>();

function storageKey(sessionId: string): string {
  return `${CACHE_PREFIX}${sessionId}`;
}

function parseContour(value: unknown): SilhouetteContour | null {
  if (typeof value !== "object" || value === null || !("loops" in value)) return null;
  const loops = (value as { loops?: unknown }).loops;
  if (!Array.isArray(loops) || loops.length === 0 || loops.length > 8) return null;
  const parsed = loops.map((loop) => {
    if (!Array.isArray(loop) || loop.length < 3 || loop.length > 200) return null;
    const points = loop.map((point) => {
      if (
        typeof point !== "object" ||
        point === null ||
        !("x" in point) ||
        !("y" in point)
      ) {
        return null;
      }
      const { x, y } = point as { x?: unknown; y?: unknown };
      return typeof x === "number" && Number.isFinite(x) && x >= 0 && x <= 1 &&
        typeof y === "number" && Number.isFinite(y) && y >= 0 && y <= 1
        ? { x, y }
        : null;
    });
    return points.every((point) => point !== null) ? points : null;
  });
  return parsed.every((loop) => loop !== null)
    ? { loops: parsed as SilhouetteContour["loops"] }
    : null;
}

export function saveReferenceSilhouette(
  sessionId: string,
  reference: ReferenceSilhouetteResult,
): void {
  try {
    window.sessionStorage.setItem(storageKey(sessionId), JSON.stringify(reference));
  } catch {
    // Runtime still works when browser storage is unavailable.
  }
}

export function loadReferenceSilhouette(sessionId: string): ReferenceSilhouetteResult {
  try {
    const raw = window.sessionStorage.getItem(storageKey(sessionId));
    if (raw === null) return { status: "extraction_failed", contour: null };
    const value = JSON.parse(raw) as { status?: unknown; contour?: unknown };
    const statuses = ["ready", "no_person", "multiple_people", "partial_person", "extraction_failed"];
    if (!statuses.includes(String(value.status))) return { status: "extraction_failed", contour: null };
    const contour = parseContour(value.contour);
    if (value.status === "ready" && contour === null) {
      return { status: "extraction_failed", contour: null };
    }
    return {
      status: value.status as ReferenceSilhouetteResult["status"],
      contour: value.status === "ready" ? contour : null,
    };
  } catch {
    return { status: "extraction_failed", contour: null };
  }
}

export function cachePreparedPoseRuntime(sessionId: string, prepared: PreparedPoseRuntime): void {
  const previous = runtimes.get(sessionId);
  if (previous !== undefined) {
    window.clearTimeout(previous.timer);
    previous.runtime.close();
  }
  saveReferenceSilhouette(sessionId, prepared.reference);
  const expiresAt = Date.now() + RUNTIME_TTL_MS;
  const timer = window.setTimeout(() => {
    const cached = runtimes.get(sessionId);
    if (cached?.expiresAt === expiresAt) {
      cached.runtime.close();
      runtimes.delete(sessionId);
    }
  }, RUNTIME_TTL_MS);
  runtimes.set(sessionId, { ...prepared, expiresAt, timer });
}

export function takePreparedPoseRuntime(sessionId: string): PoseRuntime | null {
  const cached = runtimes.get(sessionId);
  if (cached === undefined) return null;
  runtimes.delete(sessionId);
  window.clearTimeout(cached.timer);
  if (cached.expiresAt <= Date.now()) {
    cached.runtime.close();
    return null;
  }
  return cached.runtime;
}
