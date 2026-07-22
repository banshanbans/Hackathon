import { describe, expect, it } from "vitest";
import {
  binaryMaskFromProbabilities,
  contourFromMask,
  projectMediaMaskToViewport,
  rasterizeContour,
  silhouetteDice,
  transformContour,
} from "./silhouette";

function mask(rows: string[]) {
  const width = rows[0]?.length ?? 0;
  return {
    width,
    height: rows.length,
    data: Uint8Array.from(rows.join(""), (value) => (value === "1" ? 1 : 0)),
  };
}

describe("browser silhouette processing", () => {
  it("thresholds MediaPipe probabilities into a binary mask", () => {
    expect(binaryMaskFromProbabilities(new Float32Array([0.1, 0.5, 0.9, 0.49]), 2, 2)?.data)
      .toEqual(new Uint8Array([0, 1, 1, 0]));
  });

  it("rejects an empty segmentation mask", () => {
    expect(contourFromMask(mask(["000", "000", "000"]))).toBeNull();
  });

  it("extracts a tight normalized person contour and transforms it into the target", () => {
    const contour = contourFromMask(mask([
      "000000",
      "001100",
      "011110",
      "001100",
      "001100",
      "010010",
    ]));
    expect(contour).not.toBeNull();
    const points = contour?.loops.flat() ?? [];
    expect(Math.min(...points.map((point) => point.x))).toBe(0);
    expect(Math.max(...points.map((point) => point.x))).toBe(1);
    const transformed = transformContour(contour!, { x: 0.34, y: 0.42, width: 0.3, height: 0.56 });
    const transformedPoints = transformed.loops.flat();
    expect(Math.min(...transformedPoints.map((point) => point.x))).toBeCloseTo(0.34);
    expect(Math.max(...transformedPoints.map((point) => point.y))).toBeCloseTo(0.98);
  });

  it("computes exact and partial Dice matches without affecting alignment gates", () => {
    const reference = mask(["0110", "1111", "0110", "1001"]);
    const partial = mask(["0110", "1111", "0000", "0000"]);
    expect(silhouetteDice(reference, reference)).toBe(1);
    expect(silhouetteDice(reference, partial)).toBeCloseTo(0.75, 3);
  });

  it("projects a landscape camera mask through the portrait cover crop", () => {
    const source = mask([
      "001100",
      "001100",
      "001100",
      "001100",
    ]);
    const projected = projectMediaMaskToViewport(source, 6, 4, 3, 6, 3, 6);
    expect(Array.from(projected.data)).toContain(1);
    expect(projected.width).toBe(3);
    expect(projected.height).toBe(6);
  });

  it("rasterizes a transformed contour for low-resolution matching", () => {
    const contour = contourFromMask(mask(["0110", "1111", "1111", "0110"]));
    expect(contour).not.toBeNull();
    const rasterized = rasterizeContour(transformContour(contour!, {
      x: 0.25,
      y: 0.2,
      width: 0.5,
      height: 0.6,
    }), 20, 30);
    expect(rasterized.data.reduce((sum, value) => sum + value, 0)).toBeGreaterThan(0);
  });
});
