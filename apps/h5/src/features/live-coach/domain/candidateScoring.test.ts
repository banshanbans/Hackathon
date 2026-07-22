import { describe, expect, it } from "vitest";
import type { PreparedImage } from "../../../media/processing";
import { rankCandidates, scoreCandidate } from "./candidateScoring";
import type { AlignmentDecision } from "./alignmentModels";

const image: PreparedImage = {
  blob: new Blob(["jpeg"], { type: "image/jpeg" }),
  previewUrl: "blob:test",
  width: 720,
  height: 1280,
  mediaType: "image",
};

function decision(overrides: Partial<AlignmentDecision> = {}): AlignmentDecision {
  return {
    personDetected: true,
    multiplePeople: false,
    fullBodyVisible: true,
    positionStatus: "centered",
    scaleStatus: "correct",
    poseStatus: "acceptable",
    instructionCode: "ready_to_capture",
    readyToCapture: true,
    stabilityScore: 0.9,
    selectedPerson: {
      id: "one",
      joints: {},
      boundingBox: { x: 0.3, y: 0.1, width: 0.4, height: 0.8 },
      confidence: 0.9,
      observedAt: 0,
    },
    overlapRatio: 0.88,
    countdownStillValid: true,
    stableDuration: 1_300,
    completionMode: "verified",
    manualReadyAvailable: false,
    poseCheckSupported: true,
    instructionConfirmed: true,
    latencyMilliseconds: 70,
    ...overrides,
  };
}

describe("H5 local candidate scoring", () => {
  it("uses the W5 weights and penalizes unsafe candidates", () => {
    const good = scoreCandidate("good", image, 1, decision(), 0.8);
    const multiple = scoreCandidate("multiple", image, 2, decision({ multiplePeople: true }), 0.8);
    expect(good.localScore).toBeGreaterThan(multiple.localScore);
    expect(multiple.reasons).toContain("画面里出现了其他人");
    expect(rankCandidates([multiple, good])[0]?.id).toBe("good");
  });
});
