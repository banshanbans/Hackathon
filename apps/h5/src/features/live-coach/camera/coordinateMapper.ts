import {
  bodyJoints,
  type BodyJoint,
  type NormalizedPoint,
  type NormalizedRect,
  type PersonObservation,
  type PoseJoint,
} from "../domain/alignmentModels";

export type PixelRect = { x: number; y: number; width: number; height: number };

export function aspectFillGeometry(
  mediaWidth: number,
  mediaHeight: number,
  viewWidth: number,
  viewHeight: number,
): PixelRect {
  if (mediaWidth <= 0 || mediaHeight <= 0 || viewWidth <= 0 || viewHeight <= 0) {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  const scale = Math.max(viewWidth / mediaWidth, viewHeight / mediaHeight);
  const width = mediaWidth * scale;
  const height = mediaHeight * scale;
  return { x: (viewWidth - width) / 2, y: (viewHeight - height) / 2, width, height };
}

export function aspectFillRect(
  rect: NormalizedRect,
  mediaWidth: number,
  mediaHeight: number,
  viewWidth: number,
  viewHeight: number,
): PixelRect {
  const image = aspectFillGeometry(mediaWidth, mediaHeight, viewWidth, viewHeight);
  return {
    x: image.x + rect.x * image.width,
    y: image.y + rect.y * image.height,
    width: rect.width * image.width,
    height: rect.height * image.height,
  };
}

export function aspectFillPoint(
  point: NormalizedPoint,
  mediaWidth: number,
  mediaHeight: number,
  viewWidth: number,
  viewHeight: number,
): NormalizedPoint {
  const image = aspectFillGeometry(mediaWidth, mediaHeight, viewWidth, viewHeight);
  return { x: image.x + point.x * image.width, y: image.y + point.y * image.height };
}

/** Maps a ShotPlan screen-space rectangle directly into the visible viewport. */
export function viewportRect(
  rect: NormalizedRect,
  viewWidth: number,
  viewHeight: number,
): PixelRect {
  if (viewWidth <= 0 || viewHeight <= 0) return { x: 0, y: 0, width: 0, height: 0 };
  return {
    x: rect.x * viewWidth,
    y: rect.y * viewHeight,
    width: rect.width * viewWidth,
    height: rect.height * viewHeight,
  };
}

/** Maps a ShotPlan screen-space point directly into the visible viewport. */
export function viewportPoint(
  point: NormalizedPoint,
  viewWidth: number,
  viewHeight: number,
): NormalizedPoint {
  if (viewWidth <= 0 || viewHeight <= 0) return { x: 0, y: 0 };
  return { x: point.x * viewWidth, y: point.y * viewHeight };
}

function mediaPointToViewport(
  point: NormalizedPoint,
  mediaWidth: number,
  mediaHeight: number,
  viewWidth: number,
  viewHeight: number,
): NormalizedPoint | null {
  if (viewWidth <= 0 || viewHeight <= 0) return null;
  const pixel = aspectFillPoint(point, mediaWidth, mediaHeight, viewWidth, viewHeight);
  const mapped = { x: pixel.x / viewWidth, y: pixel.y / viewHeight };
  return mapped.x >= 0 && mapped.x <= 1 && mapped.y >= 0 && mapped.y <= 1 ? mapped : null;
}

function mediaRectToViewport(
  rect: NormalizedRect,
  mediaWidth: number,
  mediaHeight: number,
  viewWidth: number,
  viewHeight: number,
): NormalizedRect | null {
  if (viewWidth <= 0 || viewHeight <= 0) return null;
  const pixel = aspectFillRect(rect, mediaWidth, mediaHeight, viewWidth, viewHeight);
  const left = Math.max(0, pixel.x);
  const top = Math.max(0, pixel.y);
  const right = Math.min(viewWidth, pixel.x + pixel.width);
  const bottom = Math.min(viewHeight, pixel.y + pixel.height);
  if (right <= left || bottom <= top) return null;
  return {
    x: left / viewWidth,
    y: top / viewHeight,
    width: (right - left) / viewWidth,
    height: (bottom - top) / viewHeight,
  };
}

/**
 * Converts MediaPipe coordinates from the uncropped camera frame into the same
 * normalized screen space used by ShotPlan. Joints cropped by object-fit: cover
 * are omitted so they cannot be mistaken for visible head or feet landmarks.
 */
export function mediaObservationToViewport(
  observation: PersonObservation,
  mediaWidth: number,
  mediaHeight: number,
  viewWidth: number,
  viewHeight: number,
): PersonObservation | null {
  const boundingBox = mediaRectToViewport(
    observation.boundingBox,
    mediaWidth,
    mediaHeight,
    viewWidth,
    viewHeight,
  );
  if (boundingBox === null) return null;
  const joints: Partial<Record<BodyJoint, PoseJoint>> = {};
  for (const name of bodyJoints) {
    const joint = observation.joints[name];
    if (joint === undefined) continue;
    const point = mediaPointToViewport(
      joint.point,
      mediaWidth,
      mediaHeight,
      viewWidth,
      viewHeight,
    );
    if (point !== null) joints[name] = { ...joint, point };
  }
  return { ...observation, joints, boundingBox };
}
