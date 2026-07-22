import { describe, expect, it } from "vitest";
import { aspectFillGeometry, aspectFillRect } from "./coordinateMapper";

describe("browser aspect-fill coordinate mapping", () => {
  it("uses one crop for target and person overlays", () => {
    expect(aspectFillGeometry(1280, 720, 390, 844)).toEqual({
      x: expect.any(Number),
      y: 0,
      width: expect.any(Number),
      height: 844,
    });
    const full = aspectFillRect({ x: 0, y: 0, width: 1, height: 1 }, 720, 1280, 390, 844);
    expect(full.x).toBeCloseTo(-42.375, 3);
    expect(full.y).toBe(0);
    expect(full.height).toBe(844);
  });

  it("returns a safe zero geometry before video metadata is available", () => {
    expect(aspectFillGeometry(0, 0, 390, 844)).toEqual({ x: 0, y: 0, width: 0, height: 0 });
  });
});
