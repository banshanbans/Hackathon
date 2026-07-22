import { describe, expect, it } from "vitest";
import type { Capture } from "./apiClient";
import { buildResultComparisonItems } from "./resultComparison";

function capture(round: 1 | 2): Capture {
  return {
    schema_version: "1.0",
    capture_id: `cap_${round}`,
    session_id: "ss_comparison",
    round_index: round,
    media_asset_id: `media_${round}`,
    status: "ready",
    selected_frame_id: null,
    created_at: "2026-07-22T00:00:00Z",
  };
}

describe("result comparison mapping", () => {
  it("keeps the reference first and only exposes available captures", () => {
    expect(buildResultComparisonItems([]).map((item) => item.label)).toEqual(["参考"]);
    expect(buildResultComparisonItems([capture(1)]).map((item) => item.label)).toEqual([
      "参考",
      "第一拍",
    ]);
    expect(buildResultComparisonItems([capture(2), capture(1)]).map((item) => item.label)).toEqual([
      "参考",
      "第一拍",
      "第二拍",
    ]);
  });

  it("provides stable accessibility labels", () => {
    expect(
      buildResultComparisonItems([capture(1), capture(2)]).map(
        (item) => item.accessibilityLabel,
      ),
    ).toEqual(["参考图", "第一拍照片", "第二拍照片"]);
  });
});
