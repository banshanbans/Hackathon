import type { NormalizedPoint, NormalizedRect } from "../domain/alignmentModels";

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
