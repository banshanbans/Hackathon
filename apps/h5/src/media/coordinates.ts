export type NormalizedBox = { x: number; y: number; width: number; height: number };
export type ContainRect = { x: number; y: number; width: number; height: number };

export function containRect(
  containerWidth: number,
  containerHeight: number,
  mediaWidth: number,
  mediaHeight: number,
): ContainRect {
  if (
    containerWidth <= 0 ||
    containerHeight <= 0 ||
    mediaWidth <= 0 ||
    mediaHeight <= 0
  ) {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  const scale = Math.min(containerWidth / mediaWidth, containerHeight / mediaHeight);
  const width = mediaWidth * scale;
  const height = mediaHeight * scale;
  return {
    x: (containerWidth - width) / 2,
    y: (containerHeight - height) / 2,
    width,
    height,
  };
}

export function clientPointToNormalized(
  clientX: number,
  clientY: number,
  containerLeft: number,
  containerTop: number,
  mediaRect: ContainRect,
): { x: number; y: number } {
  if (mediaRect.width === 0 || mediaRect.height === 0) {
    return { x: 0, y: 0 };
  }
  return {
    x: Math.min(1, Math.max(0, (clientX - containerLeft - mediaRect.x) / mediaRect.width)),
    y: Math.min(1, Math.max(0, (clientY - containerTop - mediaRect.y) / mediaRect.height)),
  };
}

export function moveBox(box: NormalizedBox, centerX: number, centerY: number): NormalizedBox {
  return {
    ...box,
    x: Math.min(1 - box.width, Math.max(0, centerX - box.width / 2)),
    y: Math.min(1 - box.height, Math.max(0, centerY - box.height / 2)),
  };
}

export function resizeBox(box: NormalizedBox, scale: number): NormalizedBox {
  const centerX = box.x + box.width / 2;
  const centerY = box.y + box.height / 2;
  const width = Math.min(0.95, Math.max(0.08, box.width * scale));
  const height = Math.min(0.95, Math.max(0.08, box.height * scale));
  return moveBox({ x: box.x, y: box.y, width, height }, centerX, centerY);
}
