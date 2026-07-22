import { describe, expect, it } from "vitest";
import { observationsFromMediaPipe } from "./mediapipeAdapter";

describe("MediaPipe pose adapter", () => {
  it("maps landmarks, synthesizes neck/root and derives a credible box", () => {
    const landmarks = Array.from({ length: 33 }, () => ({ x: 0.5, y: 0.5, z: 0, visibility: 0 }));
    for (const [index, x, y] of [
      [0, 0.5, 0.1],
      [11, 0.4, 0.25],
      [12, 0.6, 0.25],
      [23, 0.43, 0.55],
      [24, 0.57, 0.55],
      [27, 0.44, 0.9],
      [28, 0.56, 0.9],
    ] as const) {
      landmarks[index] = { x, y, z: 0, visibility: 0.9 };
    }
    const observations = observationsFromMediaPipe({ landmarks: [landmarks] }, 123);
    expect(observations).toHaveLength(1);
    expect(observations[0]?.joints.neck?.point).toEqual({ x: 0.5, y: 0.25 });
    expect(observations[0]?.joints.root?.point).toEqual({ x: 0.5, y: 0.55 });
    expect(observations[0]?.boundingBox.x).toBeCloseTo(0.4, 6);
    expect(observations[0]?.boundingBox.y).toBeCloseTo(0.1, 6);
    expect(observations[0]?.boundingBox.width).toBeCloseTo(0.2, 6);
    expect(observations[0]?.boundingBox.height).toBeCloseTo(0.8, 6);
    expect(observations[0]?.confidence).toBe(0.9);
  });
});
