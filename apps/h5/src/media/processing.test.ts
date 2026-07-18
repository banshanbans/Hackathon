// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";
import { MAX_VIDEO_BYTES, inspectVideo, normalizeImage } from "./processing";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("browser media processing", () => {
  it("honors EXIF orientation and scales the longest edge to 2048px", async () => {
    const close = vi.fn();
    const bitmap = { width: 4000, height: 2000, close } as unknown as ImageBitmap;
    const createBitmap = vi.fn().mockResolvedValue(bitmap);
    const drawImage = vi.fn();
    vi.stubGlobal("createImageBitmap", createBitmap);
    vi.stubGlobal("URL", {
      createObjectURL: vi.fn().mockReturnValue("blob:normalized"),
      revokeObjectURL: vi.fn(),
    });
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({
      drawImage,
    } as unknown as CanvasRenderingContext2D);
    vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation((callback) => {
      callback(new Blob(["jpeg"], { type: "image/jpeg" }));
    });

    const source = new Blob(["source"], { type: "image/jpeg" });
    const result = await normalizeImage(source);

    expect(createBitmap).toHaveBeenCalledWith(source, { imageOrientation: "from-image" });
    expect(drawImage).toHaveBeenCalledWith(bitmap, 0, 0, 2048, 1024);
    expect(result).toMatchObject({
      previewUrl: "blob:normalized",
      width: 2048,
      height: 1024,
      mediaType: "image",
    });
    expect(close).toHaveBeenCalledOnce();
  });

  it("rejects a video above the browser-only 100MB limit before decoding", async () => {
    const file = new File(["video"], "clip.mp4", { type: "video/mp4" });
    Object.defineProperty(file, "size", { value: MAX_VIDEO_BYTES + 1 });

    await expect(inspectVideo(file)).rejects.toThrow("MEDIA_TOO_LARGE");
  });
});
