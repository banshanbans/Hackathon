import { normalizeImage, type PreparedImage } from "../../../media/processing";

function canvasBlob(canvas: HTMLCanvasElement, quality: number): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob === null ? reject(new Error("IMAGE_ENCODE_FAILED")) : resolve(blob)),
      "image/jpeg",
      quality,
    );
  });
}

export async function captureVideoFrame(video: HTMLVideoElement): Promise<PreparedImage> {
  if (video.videoWidth <= 0 || video.videoHeight <= 0) throw new Error("CAMERA_FRAME_UNAVAILABLE");
  const canvas = document.createElement("canvas");
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  const context = canvas.getContext("2d");
  if (context === null) throw new Error("CANVAS_UNAVAILABLE");
  context.drawImage(video, 0, 0, canvas.width, canvas.height);
  return normalizeImage(await canvasBlob(canvas, 0.9));
}

export async function sharpnessScore(blob: Blob): Promise<number> {
  const bitmap = await createImageBitmap(blob);
  try {
    const size = 96;
    const canvas = document.createElement("canvas");
    canvas.width = size;
    canvas.height = size;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (context === null) return 0;
    context.drawImage(bitmap, 0, 0, size, size);
    const data = context.getImageData(0, 0, size, size).data;
    const gray = new Float64Array(size * size);
    for (let index = 0; index < gray.length; index += 1) {
      const offset = index * 4;
      gray[index] =
        (data[offset] ?? 0) * 0.299 +
        (data[offset + 1] ?? 0) * 0.587 +
        (data[offset + 2] ?? 0) * 0.114;
    }
    let sum = 0;
    let sumSquared = 0;
    let count = 0;
    for (let y = 1; y < size - 1; y += 1) {
      for (let x = 1; x < size - 1; x += 1) {
        const index = y * size + x;
        const value =
          (gray[index - size] ?? 0) +
          (gray[index + size] ?? 0) +
          (gray[index - 1] ?? 0) +
          (gray[index + 1] ?? 0) -
          4 * (gray[index] ?? 0);
        sum += value;
        sumSquared += value * value;
        count += 1;
      }
    }
    if (count === 0) return 0;
    const variance = sumSquared / count - (sum / count) ** 2;
    return Math.min(1, Math.max(0, variance / 1_200));
  } finally {
    bitmap.close();
  }
}
