export const MAX_IMAGE_BYTES = 8_000_000;
export const MAX_IMAGE_EDGE = 2048;
export const MAX_VIDEO_BYTES = 100_000_000;
export const MAX_VIDEO_SECONDS = 30;

export type PreparedImage = {
  blob: Blob;
  previewUrl: string;
  width: number;
  height: number;
  mediaType: "image" | "video_frame";
};

function canvasToBlob(canvas: HTMLCanvasElement, quality: number): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob === null ? reject(new Error("IMAGE_ENCODE_FAILED")) : resolve(blob)),
      "image/jpeg",
      quality,
    );
  });
}

async function encodeWithinLimit(canvas: HTMLCanvasElement): Promise<Blob> {
  for (const quality of [0.9, 0.82, 0.72, 0.62]) {
    const blob = await canvasToBlob(canvas, quality);
    if (blob.size <= MAX_IMAGE_BYTES) {
      return blob;
    }
  }
  throw new Error("MEDIA_TOO_LARGE");
}

function fitSize(width: number, height: number): { width: number; height: number } {
  const scale = Math.min(1, MAX_IMAGE_EDGE / Math.max(width, height));
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

export async function normalizeImage(
  source: Blob,
  mediaType: PreparedImage["mediaType"] = "image",
): Promise<PreparedImage> {
  const bitmap = await createImageBitmap(source, { imageOrientation: "from-image" });
  try {
    const size = fitSize(bitmap.width, bitmap.height);
    const canvas = document.createElement("canvas");
    canvas.width = size.width;
    canvas.height = size.height;
    const context = canvas.getContext("2d");
    if (context === null) {
      throw new Error("CANVAS_UNAVAILABLE");
    }
    context.drawImage(bitmap, 0, 0, size.width, size.height);
    const blob = await encodeWithinLimit(canvas);
    return {
      blob,
      previewUrl: URL.createObjectURL(blob),
      width: size.width,
      height: size.height,
      mediaType,
    };
  } finally {
    bitmap.close();
  }
}

function loadVideo(file: File): Promise<{ element: HTMLVideoElement; url: string }> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const element = document.createElement("video");
    element.preload = "metadata";
    element.muted = true;
    element.playsInline = true;
    element.onloadedmetadata = () => resolve({ element, url });
    element.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("UNSUPPORTED_MEDIA"));
    };
    element.src = url;
  });
}

export async function inspectVideo(file: File): Promise<number> {
  if (file.size > MAX_VIDEO_BYTES) {
    throw new Error("MEDIA_TOO_LARGE");
  }
  const loaded = await loadVideo(file);
  try {
    if (!Number.isFinite(loaded.element.duration) || loaded.element.duration > MAX_VIDEO_SECONDS) {
      throw new Error("VIDEO_TOO_LONG");
    }
    return loaded.element.duration;
  } finally {
    URL.revokeObjectURL(loaded.url);
  }
}

export async function extractVideoFrame(file: File, seconds: number): Promise<PreparedImage> {
  const loaded = await loadVideo(file);
  try {
    const video = loaded.element;
    if (!Number.isFinite(video.duration) || video.duration > MAX_VIDEO_SECONDS) {
      throw new Error("VIDEO_TOO_LONG");
    }
    await new Promise<void>((resolve, reject) => {
      video.onseeked = () => resolve();
      video.onerror = () => reject(new Error("VIDEO_FRAME_FAILED"));
      video.currentTime = Math.min(Math.max(0, seconds), Math.max(0, video.duration - 0.01));
    });
    const canvas = document.createElement("canvas");
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    const context = canvas.getContext("2d");
    if (context === null) {
      throw new Error("CANVAS_UNAVAILABLE");
    }
    context.drawImage(video, 0, 0);
    return normalizeImage(await canvasToBlob(canvas, 0.92), "video_frame");
  } finally {
    URL.revokeObjectURL(loaded.url);
  }
}

export async function sha256(blob: Blob): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer());
  return [...new Uint8Array(digest)]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}
