// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";
import {
  MAX_IMAGE_BYTES,
  MAX_VIDEO_BYTES,
  inspectVideo,
  normalizeImage,
} from "./processing";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("browser media processing", () => {
  it("honors EXIF orientation and scales the longest edge to 1280px", async () => {
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
    expect(drawImage).toHaveBeenCalledWith(bitmap, 0, 0, 1280, 640);
    expect(result).toMatchObject({
      previewUrl: "blob:normalized",
      width: 1280,
      height: 640,
      mediaType: "image",
    });
    expect(close).toHaveBeenCalledOnce();
  });

  it("does not upscale a small image", async () => {
    const bitmap = { width: 640, height: 480, close: vi.fn() } as unknown as ImageBitmap;
    vi.stubGlobal("createImageBitmap", vi.fn().mockResolvedValue(bitmap));
    vi.stubGlobal("URL", {
      createObjectURL: vi.fn().mockReturnValue("blob:small"),
      revokeObjectURL: vi.fn(),
    });
    const drawImage = vi.fn();
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({
      drawImage,
    } as unknown as CanvasRenderingContext2D);
    vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation((callback) => {
      callback(new Blob(["small"], { type: "image/jpeg" }));
    });

    const result = await normalizeImage(new Blob(["source"], { type: "image/jpeg" }));

    expect(drawImage).toHaveBeenCalledWith(bitmap, 0, 0, 640, 480);
    expect(result).toMatchObject({ width: 640, height: 480 });
  });

  it("tries 0.82, 0.78 and 0.75 before reducing dimensions", async () => {
    const bitmap = { width: 1280, height: 960, close: vi.fn() } as unknown as ImageBitmap;
    vi.stubGlobal("createImageBitmap", vi.fn().mockResolvedValue(bitmap));
    vi.stubGlobal("URL", {
      createObjectURL: vi.fn().mockReturnValue("blob:compressed"),
      revokeObjectURL: vi.fn(),
    });
    const drawImage = vi.fn();
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({
      drawImage,
    } as unknown as CanvasRenderingContext2D);
    const qualities: number[] = [];
    vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation(
      (callback, _type, quality) => {
        qualities.push(quality ?? 0);
        const oversized = qualities.length <= 3;
        const size = oversized ? MAX_IMAGE_BYTES + 1 : 10;
        callback(new Blob([new Uint8Array(size)], { type: "image/jpeg" }));
      },
    );

    const result = await normalizeImage(new Blob(["source"], { type: "image/jpeg" }));

    expect(qualities.slice(0, 4)).toEqual([0.82, 0.78, 0.75, 0.75]);
    expect(drawImage).toHaveBeenNthCalledWith(1, bitmap, 0, 0, 1280, 960);
    expect(drawImage).toHaveBeenNthCalledWith(2, bitmap, 0, 0, 1088, 816);
    expect(result).toMatchObject({ width: 1088, height: 816 });
    expect(result.blob.size).toBeLessThanOrEqual(MAX_IMAGE_BYTES);
  });

  it("rejects a video above the browser-only 100MB limit before decoding", async () => {
    const file = new File(["video"], "clip.mp4", { type: "video/mp4" });
    Object.defineProperty(file, "size", { value: MAX_VIDEO_BYTES + 1 });

    await expect(inspectVideo(file)).rejects.toThrow("MEDIA_TOO_LARGE");
  });
});
