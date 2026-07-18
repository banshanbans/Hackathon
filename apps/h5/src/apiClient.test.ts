// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";
import { SoloShotApiError, soloShotApi } from "./apiClient";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("media upload cancellation", () => {
  it("keeps an aborted PUT recoverable and never completes the asset", async () => {
    vi.stubGlobal("crypto", {
      randomUUID: () => "00000000-0000-4000-8000-000000000000",
      subtle: { digest: vi.fn().mockResolvedValue(new Uint8Array(32).buffer) },
    });
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            data: {
              schema_version: "1.0",
              asset: {
                schema_version: "1.0",
                media_asset_id: "media_cancel_test",
                status: "pending_upload",
              },
              upload_url: "https://upload.invalid/media_cancel_test",
              upload_headers: { "Content-Type": "image/jpeg" },
              upload_expires_at: "2026-07-18T00:00:00Z",
            },
          }),
          { status: 201, headers: { "Content-Type": "application/json" } },
        ),
      )
      .mockRejectedValueOnce(new DOMException("Aborted", "AbortError"));
    vi.stubGlobal("fetch", fetchMock);
    const progress: number[] = [];

    const result = soloShotApi.uploadMedia(
      "ss_cancel_test",
      "capture",
      new Blob(["jpeg"], { type: "image/jpeg" }),
      { onProgress: (value) => progress.push(value) },
    );

    await expect(result).rejects.toMatchObject({
      code: "UPLOAD_CANCELED",
      recoverable: true,
    } satisfies Partial<SoloShotApiError>);
    expect(progress).toEqual([5, 15, 35]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
