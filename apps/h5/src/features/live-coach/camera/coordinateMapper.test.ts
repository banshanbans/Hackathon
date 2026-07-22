import { describe, expect, it } from "vitest";
import type { PersonObservation } from "../domain/alignmentModels";
import {
  aspectFillGeometry,
  aspectFillRect,
  mediaObservationToViewport,
  viewportRect,
} from "./coordinateMapper";

describe("browser aspect-fill coordinate mapping", () => {
  it("calculates the camera crop used by object-fit cover", () => {
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

  it("keeps a ShotPlan target inside the visible portrait viewport", () => {
    const target = viewportRect({ x: 0.34, y: 0.42, width: 0.3, height: 0.56 }, 390, 844);
    expect(target.x).toBeCloseTo(132.6, 3);
    expect(target.y).toBeCloseTo(354.48, 3);
    expect(target.width).toBeCloseTo(117, 3);
    expect(target.height).toBeCloseTo(472.64, 3);
  });

  it("maps MediaPipe observations through the landscape camera crop before alignment", () => {
    const observation: PersonObservation = {
      id: "pose-0",
      confidence: 0.9,
      observedAt: 100,
      boundingBox: { x: 0.4, y: 0.2, width: 0.2, height: 0.6 },
      joints: {
        nose: { point: { x: 0.5, y: 0.2 }, confidence: 0.9 },
        leftAnkle: { point: { x: 0.1, y: 0.8 }, confidence: 0.9 },
        rightAnkle: { point: { x: 0.55, y: 0.8 }, confidence: 0.9 },
      },
    };

    const mapped = mediaObservationToViewport(observation, 1920, 1440, 390, 844);

    expect(mapped?.boundingBox.x).toBeCloseTo(0.2115, 3);
    expect(mapped?.boundingBox.width).toBeCloseTo(0.5769, 3);
    expect(mapped?.boundingBox.y).toBeCloseTo(0.2, 3);
    expect(mapped?.boundingBox.height).toBeCloseTo(0.6, 3);
    expect(mapped?.joints.nose?.point).toEqual({ x: 0.5, y: 0.2 });
    expect(mapped?.joints.leftAnkle).toBeUndefined();
    expect(mapped?.joints.rightAnkle?.point.x).toBeCloseTo(0.6442, 3);
  });

  it("drops a detected person that is entirely outside the visible crop", () => {
    const observation: PersonObservation = {
      id: "pose-0",
      confidence: 0.9,
      observedAt: 100,
      boundingBox: { x: 0.02, y: 0.2, width: 0.1, height: 0.6 },
      joints: {},
    };
    expect(mediaObservationToViewport(observation, 1920, 1440, 390, 844)).toBeNull();
  });
});
