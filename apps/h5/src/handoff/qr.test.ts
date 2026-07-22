import jsQR from "jsqr";
import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { renderHandoffQrDataUrl } from "./qr";

describe("handoff QR", () => {
  it("is decoded back to the exact HTTPS landing URL", async () => {
    const payload = "https://handoff.example.test/handoff/294816";
    const dataUrl = await renderHandoffQrDataUrl(payload);
    const svg = decodeURIComponent(dataUrl.split(",", 2)[1] ?? "");
    const { data, info } = await sharp(Buffer.from(svg)).png().ensureAlpha().raw().toBuffer({
      resolveWithObject: true,
    });
    const decoded = jsQR(new Uint8ClampedArray(data), info.width, info.height);
    expect(decoded?.data).toBe(payload);
  });
});
