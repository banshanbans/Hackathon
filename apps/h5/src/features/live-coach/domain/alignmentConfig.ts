import type { BodyJoint } from "./alignmentModels";

export type CoarseArmRule = "none" | "one_wrist_above_hip" | "one_arm_extended";

export type AlignmentConfiguration = {
  jointConfidence: number;
  crediblePersonConfidence: number;
  horizontalEnterTolerance: number;
  horizontalExitTolerance: number;
  heightEnterTolerance: number;
  heightExitTolerance: number;
  overlapEnterThreshold: number;
  overlapExitThreshold: number;
  instructionConfirmationSamples: number;
  readyMinimumSamples: number;
  readyMinimumDurationMs: number;
  manualFallbackDelayMs: number;
  speechMinimumIntervalMs: number;
  nominalSampleIntervalMs: number;
  degradedSampleIntervalMs: number;
  armRules: Readonly<Record<string, CoarseArmRule>>;
};

export const alignmentConfiguration: AlignmentConfiguration = {
  jointConfidence: 0.3,
  crediblePersonConfidence: 0.25,
  horizontalEnterTolerance: 0.06,
  horizontalExitTolerance: 0.12,
  heightEnterTolerance: 0.1,
  heightExitTolerance: 0.18,
  overlapEnterThreshold: 0.8,
  overlapExitThreshold: 0.7,
  instructionConfirmationSamples: 3,
  readyMinimumSamples: 3,
  readyMinimumDurationMs: 1_200,
  manualFallbackDelayMs: 5_000,
  speechMinimumIntervalMs: 2_000,
  nominalSampleIntervalMs: 125,
  degradedSampleIntervalMs: 250,
  armRules: {
    doorway_crossed_legs: "none",
    walking_turn: "none",
    standing_turn: "none",
    wall_lean_three_quarter: "none",
    seated_forward_lean: "none",
    standing_coffee_full_body: "one_wrist_above_hip",
    profile_bottle_closeup: "one_wrist_above_hip",
    seated_drink: "one_wrist_above_hip",
    umbrella_half_body: "one_wrist_above_hip",
    foreground_receipt_reach: "one_arm_extended",
  },
};

export const landmarkIndex: Readonly<Partial<Record<BodyJoint, number>>> = {
  nose: 0,
  leftShoulder: 11,
  rightShoulder: 12,
  leftElbow: 13,
  rightElbow: 14,
  leftWrist: 15,
  rightWrist: 16,
  leftHip: 23,
  rightHip: 24,
  leftKnee: 25,
  rightKnee: 26,
  leftAnkle: 27,
  rightAnkle: 28,
};
