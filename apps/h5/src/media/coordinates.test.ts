import { describe, expect, it } from "vitest";
import { clientPointToNormalized, containRect, moveBox, resizeBox } from "./coordinates";

describe("object-fit contain coordinate mapping", () => {
  it("maps points after removing portrait side letterboxing", () => {
    const rect = containRect(390, 300, 1000, 2000);
    expect(rect).toEqual({ x: 120, y: 0, width: 150, height: 300 });
    expect(clientPointToNormalized(195, 150, 0, 0, rect)).toEqual({ x: 0.5, y: 0.5 });
  });

  it("maps points after removing landscape top and bottom letterboxing", () => {
    const rect = containRect(300, 390, 2000, 1000);
    expect(rect).toEqual({ x: 0, y: 120, width: 300, height: 150 });
    expect(clientPointToNormalized(150, 195, 0, 0, rect)).toEqual({ x: 0.5, y: 0.5 });
  });

  it("is independent from device pixel ratio and clamps drag and zoom", () => {
    const rect = containRect(390, 300, 1000, 2000);
    const cssPoint = clientPointToNormalized(195, 150, 0, 0, rect);
    const highDprSameCssPoint = clientPointToNormalized(195, 150, 0, 0, rect);
    expect(highDprSameCssPoint).toEqual(cssPoint);
    expect(moveBox({ x: 0.2, y: 0.2, width: 0.4, height: 0.5 }, 1, 1)).toEqual({
      x: 0.6,
      y: 0.5,
      width: 0.4,
      height: 0.5,
    });
    const resized = resizeBox({ x: 0.2, y: 0.2, width: 0.4, height: 0.5 }, 3);
    expect(resized.width).toBe(0.95);
    expect(resized.height).toBe(0.95);
  });
});
