import { describe, expect, it } from "vitest";
import { AlignmentEngine } from "./alignmentEngine";
import type { BodyJoint, CoachTarget, NormalizedRect, PersonObservation } from "./alignmentModels";

const target: CoachTarget = {
  rect: { x: 0.35, y: 0.1, width: 0.3, height: 0.8 },
  bodyDirection: "front",
  poseTemplate: "standing_turn",
};

function person(
  rect: NormalizedRect = target.rect,
  options: { feet?: boolean; nose?: boolean } = {},
): PersonObservation {
  const points: Partial<Record<BodyJoint, { x: number; y: number }>> = {
    nose: { x: 0.5, y: 0.13 },
    neck: { x: 0.5, y: 0.25 },
    leftShoulder: { x: 0.44, y: 0.26 },
    rightShoulder: { x: 0.56, y: 0.26 },
    leftHip: { x: 0.46, y: 0.55 },
    rightHip: { x: 0.54, y: 0.55 },
    leftAnkle: { x: 0.46, y: 0.87 },
    rightAnkle: { x: 0.54, y: 0.87 },
  };
  if (options.feet === false) {
    delete points.leftAnkle;
    delete points.rightAnkle;
  }
  if (options.nose === false) {
    delete points.nose;
    delete points.neck;
  }
  return {
    id: "person",
    joints: Object.fromEntries(
      Object.entries(points).map(([name, point]) => [name, { point, confidence: 0.95 }]),
    ),
    boundingBox: rect,
    confidence: 0.9,
    observedAt: 0,
  };
}

function confirm(engine: AlignmentEngine, observations: PersonObservation[], start = 0) {
  let result = engine.process(observations, start);
  result = engine.process(observations, start + 100);
  return engine.process(observations, start + 200);
}

describe("H5 AlignmentEngine", () => {
  it("uses the same no-person, multi-person and completeness priorities as iOS", () => {
    expect(confirm(new AlignmentEngine(target, undefined, 0), []).instructionCode).toBe("no_person");
    expect(
      confirm(new AlignmentEngine(target, undefined, 0), [person(), { ...person(), id: "two" }])
        .instructionCode,
    ).toBe("multiple_people");
    expect(
      confirm(new AlignmentEngine(target, undefined, 0), [person(target.rect, { feet: false })])
        .instructionCode,
    ).toBe("feet_outside");
    expect(
      confirm(new AlignmentEngine(target, undefined, 0), [person(target.rect, { nose: false })])
        .instructionCode,
    ).toBe("head_outside");
  });

  it("enters at 80% IoU after 1.2 seconds and preserves composition-only honesty", () => {
    const engine = new AlignmentEngine(target, undefined, 0);
    const rect = { ...target.rect, width: target.rect.width * 0.8, x: 0.38 };
    let result = engine.process([person(rect)], 0);
    for (const time of [100, 200, 1_200, 1_300, 1_400]) result = engine.process([person(rect)], time);
    expect(result.overlapRatio).toBeCloseTo(0.8, 6);
    expect(result.readyToCapture).toBe(true);
    expect(result.completionMode).toBe("verified");
  });

  it("uses the 70% boundary to cancel countdown", () => {
    const atBoundary = new AlignmentEngine(target, undefined, 0).process(
      [person({ ...target.rect, width: target.rect.width * 0.7, x: 0.395 })],
      0,
    );
    const below = new AlignmentEngine(target, undefined, 0).process(
      [person({ ...target.rect, width: target.rect.width * 0.699, x: 0.39515 })],
      0,
    );
    expect(atBoundary.overlapRatio).toBeCloseTo(0.7, 6);
    expect(atBoundary.countdownStillValid).toBe(true);
    expect(below.countdownStillValid).toBe(false);
  });

  it("offers an explicitly manual completion only after five seconds", () => {
    const engine = new AlignmentEngine(target, undefined, 0);
    expect(engine.process([], 4_999).manualReadyAvailable).toBe(false);
    expect(engine.process([], 5_000).manualReadyAvailable).toBe(true);
    expect(engine.manualCompletion().completionMode).toBe("manual");
  });
});
