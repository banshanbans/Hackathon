export type NormalizedPoint = { x: number; y: number };

export type NormalizedRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export const bodyJoints = [
  "nose",
  "neck",
  "leftShoulder",
  "rightShoulder",
  "leftElbow",
  "rightElbow",
  "leftWrist",
  "rightWrist",
  "root",
  "leftHip",
  "rightHip",
  "leftKnee",
  "rightKnee",
  "leftAnkle",
  "rightAnkle",
] as const;

export type BodyJoint = (typeof bodyJoints)[number];

export type PoseJoint = { point: NormalizedPoint; confidence: number };

export type PersonObservation = {
  id: string;
  joints: Partial<Record<BodyJoint, PoseJoint>>;
  boundingBox: NormalizedRect;
  confidence: number;
  observedAt: number;
};

export type CoachTarget = {
  rect: NormalizedRect;
  bodyDirection: string;
  poseTemplate: string;
};

export type InstructionCode =
  | "no_person"
  | "multiple_people"
  | "head_outside"
  | "feet_outside"
  | "move_left"
  | "move_right"
  | "move_forward"
  | "move_backward"
  | "adjust_body_direction"
  | "adjust_arm"
  | "hold_still"
  | "ready_to_capture";

export type CompletionMode = "verified" | "composition_only" | "manual";

export type AlignmentDecision = {
  personDetected: boolean;
  multiplePeople: boolean;
  fullBodyVisible: boolean;
  positionStatus: "unknown" | "centered" | "move_left" | "move_right";
  scaleStatus: "unknown" | "correct" | "move_forward" | "move_backward";
  poseStatus: "unknown" | "acceptable" | "adjust";
  instructionCode: InstructionCode;
  readyToCapture: boolean;
  stabilityScore: number;
  selectedPerson: PersonObservation | null;
  overlapRatio: number;
  silhouetteScore: number | null;
  countdownStillValid: boolean;
  stableDuration: number;
  completionMode: CompletionMode | null;
  manualReadyAvailable: boolean;
  poseCheckSupported: boolean;
  instructionConfirmed: boolean;
  latencyMilliseconds: number;
};

export function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}

export function normalizedRect(rect: NormalizedRect): NormalizedRect {
  const x = clamp01(rect.x);
  const y = clamp01(rect.y);
  return {
    x,
    y,
    width: Math.min(Math.max(0, rect.width), 1 - x),
    height: Math.min(Math.max(0, rect.height), 1 - y),
  };
}

export function center(rect: NormalizedRect): NormalizedPoint {
  return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
}

export function intersectionOverUnion(a: NormalizedRect, b: NormalizedRect): number {
  const width = Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x));
  const height = Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));
  const intersection = width * height;
  const union = a.width * a.height + b.width * b.height - intersection;
  return union > 0 ? intersection / union : 0;
}

export function joint(
  person: PersonObservation,
  name: BodyJoint,
  minimumConfidence: number,
): PoseJoint | null {
  const value = person.joints[name];
  return value !== undefined && value.confidence >= minimumConfidence ? value : null;
}
