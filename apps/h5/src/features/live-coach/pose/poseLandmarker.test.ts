import { describe, expect, it } from "vitest";
import type { PersonObservation } from "../domain/alignmentModels";
import { isPartialReferencePerson } from "./poseLandmarker";

function observation(overrides: Partial<PersonObservation> = {}): PersonObservation {
  return {
    id: "pose-0",
    confidence: 0.9,
    observedAt: 0,
    boundingBox: { x: 0.25, y: 0.05, width: 0.5, height: 0.9 },
    joints: {
      nose: { point: { x: 0.5, y: 0.08 }, confidence: 0.9 },
      leftAnkle: { point: { x: 0.4, y: 0.93 }, confidence: 0.9 },
      rightAnkle: { point: { x: 0.6, y: 0.93 }, confidence: 0.9 },
    },
    ...overrides,
  };
}

describe("reference person classification", () => {
  it("accepts a complete person with head and both feet visible", () => {
    expect(isPartialReferencePerson(observation())).toBe(false);
  });

  it("marks edge-clipped and missing-feet people as partial", () => {
    expect(isPartialReferencePerson(observation({
      boundingBox: { x: 0, y: 0.05, width: 0.5, height: 0.9 },
    }))).toBe(true);
    expect(isPartialReferencePerson(observation({
      joints: { nose: { point: { x: 0.5, y: 0.08 }, confidence: 0.9 } },
    }))).toBe(true);
  });
});
