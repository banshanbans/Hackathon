import { aspectFillGeometry } from "../camera/coordinateMapper";
import type { NormalizedPoint, NormalizedRect } from "./alignmentModels";

export type BinarySilhouetteMask = {
  width: number;
  height: number;
  data: Uint8Array;
};

export type SilhouetteContour = {
  loops: NormalizedPoint[][];
};

type GridPoint = { x: number; y: number };
type Edge = { start: GridPoint; end: GridPoint };

const pointKey = (point: GridPoint) => `${point.x},${point.y}`;

export function binaryMaskFromProbabilities(
  values: Float32Array | Uint8Array,
  width: number,
  height: number,
  threshold = 0.5,
): BinarySilhouetteMask | null {
  if (width <= 0 || height <= 0 || values.length !== width * height) return null;
  const data = new Uint8Array(values.length);
  const byteInput = values instanceof Uint8Array;
  const cutoff = byteInput ? threshold * 255 : threshold;
  for (let index = 0; index < values.length; index += 1) {
    data[index] = (values[index] ?? 0) >= cutoff ? 1 : 0;
  }
  return { width, height, data };
}

function maskValue(mask: BinarySilhouetteMask, x: number, y: number): number {
  if (x < 0 || y < 0 || x >= mask.width || y >= mask.height) return 0;
  return mask.data[y * mask.width + x] ?? 0;
}

function boundaryEdges(mask: BinarySilhouetteMask): Edge[] {
  const edges: Edge[] = [];
  for (let y = 0; y < mask.height; y += 1) {
    for (let x = 0; x < mask.width; x += 1) {
      if (maskValue(mask, x, y) === 0) continue;
      if (maskValue(mask, x, y - 1) === 0) {
        edges.push({ start: { x, y }, end: { x: x + 1, y } });
      }
      if (maskValue(mask, x + 1, y) === 0) {
        edges.push({ start: { x: x + 1, y }, end: { x: x + 1, y: y + 1 } });
      }
      if (maskValue(mask, x, y + 1) === 0) {
        edges.push({ start: { x: x + 1, y: y + 1 }, end: { x, y: y + 1 } });
      }
      if (maskValue(mask, x - 1, y) === 0) {
        edges.push({ start: { x, y: y + 1 }, end: { x, y } });
      }
    }
  }
  return edges;
}

function direction(edge: Edge): number {
  if (edge.end.x > edge.start.x) return 0;
  if (edge.end.y > edge.start.y) return 1;
  if (edge.end.x < edge.start.x) return 2;
  return 3;
}

function traceLoops(edges: Edge[]): GridPoint[][] {
  const outgoing = new Map<string, number[]>();
  edges.forEach((edge, index) => {
    const key = pointKey(edge.start);
    outgoing.set(key, [...(outgoing.get(key) ?? []), index]);
  });
  const used = new Set<number>();
  const loops: GridPoint[][] = [];
  for (let startIndex = 0; startIndex < edges.length; startIndex += 1) {
    if (used.has(startIndex)) continue;
    const first = edges[startIndex];
    if (first === undefined) continue;
    const loop: GridPoint[] = [first.start];
    let edgeIndex = startIndex;
    let guard = 0;
    while (!used.has(edgeIndex) && guard <= edges.length) {
      guard += 1;
      used.add(edgeIndex);
      const edge = edges[edgeIndex];
      if (edge === undefined) break;
      if (pointKey(edge.end) === pointKey(first.start)) break;
      loop.push(edge.end);
      const candidates = (outgoing.get(pointKey(edge.end)) ?? []).filter((index) => !used.has(index));
      if (candidates.length === 0) break;
      const currentDirection = direction(edge);
      candidates.sort((left, right) => {
        const leftTurn = (direction(edges[left] ?? edge) - currentDirection + 4) % 4;
        const rightTurn = (direction(edges[right] ?? edge) - currentDirection + 4) % 4;
        const preference = [1, 0, 3, 2];
        return preference.indexOf(leftTurn) - preference.indexOf(rightTurn);
      });
      edgeIndex = candidates[0] ?? edgeIndex;
    }
    if (loop.length >= 3) loops.push(loop);
  }
  return loops;
}

function signedArea(points: NormalizedPoint[]): number {
  return points.reduce((sum, point, index) => {
    const next = points[(index + 1) % points.length] ?? point;
    return sum + point.x * next.y - next.x * point.y;
  }, 0) / 2;
}

function limitPoints(points: NormalizedPoint[], maximum = 160): NormalizedPoint[] {
  if (points.length <= maximum) return points;
  const step = points.length / maximum;
  return Array.from({ length: maximum }, (_, index) => points[Math.floor(index * step)]).filter(
    (point): point is NormalizedPoint => point !== undefined,
  );
}

export function contourFromMask(mask: BinarySilhouetteMask): SilhouetteContour | null {
  const rawLoops = traceLoops(boundaryEdges(mask));
  if (rawLoops.length === 0) return null;
  const normalized = rawLoops
    .map((loop) =>
      limitPoints(loop.map((point) => ({ x: point.x / mask.width, y: point.y / mask.height }))),
    )
    .map((loop) => ({ loop, area: Math.abs(signedArea(loop)) }))
    .sort((left, right) => right.area - left.area);
  const largestArea = normalized[0]?.area ?? 0;
  const useful = normalized.filter(({ area }) => area >= Math.max(0.0005, largestArea * 0.005));
  const points = useful.flatMap(({ loop }) => loop);
  const minX = Math.min(...points.map((point) => point.x));
  const minY = Math.min(...points.map((point) => point.y));
  const maxX = Math.max(...points.map((point) => point.x));
  const maxY = Math.max(...points.map((point) => point.y));
  const width = maxX - minX;
  const height = maxY - minY;
  if (width <= 0 || height <= 0) return null;
  return {
    loops: useful.map(({ loop }) =>
      loop.map((point) => ({ x: (point.x - minX) / width, y: (point.y - minY) / height })),
    ),
  };
}

export function transformContour(
  contour: SilhouetteContour,
  rect: NormalizedRect,
): SilhouetteContour {
  return {
    loops: contour.loops.map((loop) =>
      loop.map((point) => ({
        x: rect.x + point.x * rect.width,
        y: rect.y + point.y * rect.height,
      })),
    ),
  };
}

function pointInsideContour(point: NormalizedPoint, contour: SilhouetteContour): boolean {
  let inside = false;
  for (const loop of contour.loops) {
    for (let index = 0, previous = loop.length - 1; index < loop.length; previous = index, index += 1) {
      const currentPoint = loop[index];
      const previousPoint = loop[previous];
      if (currentPoint === undefined || previousPoint === undefined) continue;
      const crosses =
        currentPoint.y > point.y !== previousPoint.y > point.y &&
        point.x <
          ((previousPoint.x - currentPoint.x) * (point.y - currentPoint.y)) /
            (previousPoint.y - currentPoint.y) +
            currentPoint.x;
      if (crosses) inside = !inside;
    }
  }
  return inside;
}

export function rasterizeContour(
  contour: SilhouetteContour,
  width = 96,
  height = 160,
): BinarySilhouetteMask {
  const data = new Uint8Array(width * height);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (pointInsideContour({ x: (x + 0.5) / width, y: (y + 0.5) / height }, contour)) {
        data[y * width + x] = 1;
      }
    }
  }
  return { width, height, data };
}

export function projectMediaMaskToViewport(
  mask: BinarySilhouetteMask,
  mediaWidth: number,
  mediaHeight: number,
  viewWidth: number,
  viewHeight: number,
  outputWidth = 96,
  outputHeight = 160,
): BinarySilhouetteMask {
  const output = new Uint8Array(outputWidth * outputHeight);
  const geometry = aspectFillGeometry(mediaWidth, mediaHeight, viewWidth, viewHeight);
  if (geometry.width <= 0 || geometry.height <= 0) {
    return { width: outputWidth, height: outputHeight, data: output };
  }
  for (let y = 0; y < outputHeight; y += 1) {
    const viewY = ((y + 0.5) / outputHeight) * viewHeight;
    const sourceY = (viewY - geometry.y) / geometry.height;
    if (sourceY < 0 || sourceY > 1) continue;
    for (let x = 0; x < outputWidth; x += 1) {
      const viewX = ((x + 0.5) / outputWidth) * viewWidth;
      const sourceX = (viewX - geometry.x) / geometry.width;
      if (sourceX < 0 || sourceX > 1) continue;
      const maskX = Math.min(mask.width - 1, Math.floor(sourceX * mask.width));
      const maskY = Math.min(mask.height - 1, Math.floor(sourceY * mask.height));
      output[y * outputWidth + x] = mask.data[maskY * mask.width + maskX] ?? 0;
    }
  }
  return { width: outputWidth, height: outputHeight, data: output };
}

export function silhouetteDice(
  reference: BinarySilhouetteMask,
  live: BinarySilhouetteMask,
): number | null {
  if (
    reference.width !== live.width ||
    reference.height !== live.height ||
    reference.data.length !== live.data.length
  ) {
    return null;
  }
  let referenceCount = 0;
  let liveCount = 0;
  let intersection = 0;
  for (let index = 0; index < reference.data.length; index += 1) {
    const referenceOn = (reference.data[index] ?? 0) > 0;
    const liveOn = (live.data[index] ?? 0) > 0;
    if (referenceOn) referenceCount += 1;
    if (liveOn) liveCount += 1;
    if (referenceOn && liveOn) intersection += 1;
  }
  const total = referenceCount + liveCount;
  return total === 0 ? null : (2 * intersection) / total;
}
