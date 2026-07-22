import type { NormalizedLandmark, PoseLandmarkerResult } from "@mediapipe/tasks-vision";
import { landmarkIndex } from "../domain/alignmentConfig";
import {
  bodyJoints,
  clamp01,
  normalizedRect,
  type BodyJoint,
  type NormalizedPoint,
  type PersonObservation,
  type PoseJoint,
} from "../domain/alignmentModels";

function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  const value = sorted[middle];
  if (value === undefined) return 0;
  if (sorted.length % 2 === 1) return value;
  return ((sorted[middle - 1] ?? value) + value) / 2;
}

function midpoint(a: PoseJoint | undefined, b: PoseJoint | undefined): PoseJoint | undefined {
  if (a === undefined || b === undefined) return undefined;
  return {
    point: { x: (a.point.x + b.point.x) / 2, y: (a.point.y + b.point.y) / 2 },
    confidence: Math.min(a.confidence, b.confidence),
  };
}

function mapLandmarks(
  landmarks: NormalizedLandmark[],
  observedAt: number,
  poseIndex: number,
): PersonObservation | null {
  const joints: Partial<Record<BodyJoint, PoseJoint>> = {};
  for (const name of bodyJoints) {
    const index = landmarkIndex[name];
    if (index === undefined) continue;
    const value = landmarks[index];
    if (value === undefined || !Number.isFinite(value.x) || !Number.isFinite(value.y)) continue;
    joints[name] = {
      point: { x: clamp01(value.x), y: clamp01(value.y) },
      confidence: clamp01(value.visibility),
    };
  }
  const neck = midpoint(joints.leftShoulder, joints.rightShoulder);
  const root = midpoint(joints.leftHip, joints.rightHip);
  if (neck !== undefined) joints.neck = neck;
  if (root !== undefined) joints.root = root;

  const credible = Object.values(joints).filter((value) => value.confidence >= 0.2);
  if (credible.length === 0) return null;
  const xs = credible.map((value) => value.point.x);
  const ys = credible.map((value) => value.point.y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const confidenceJoints = [
    joints.leftShoulder,
    joints.rightShoulder,
    joints.leftHip,
    joints.rightHip,
    joints.leftKnee,
    joints.rightKnee,
    joints.leftAnkle,
    joints.rightAnkle,
  ].filter((value): value is PoseJoint => value !== undefined);
  return {
    id: `pose-${poseIndex}`,
    joints,
    boundingBox: normalizedRect({
      x: minX,
      y: minY,
      width: Math.max(maxX - minX, 0.01),
      height: Math.max(maxY - minY, 0.01),
    }),
    confidence: median(confidenceJoints.map((value) => value.confidence)),
    observedAt,
  };
}

export function observationsFromMediaPipe(
  result: Pick<PoseLandmarkerResult, "landmarks">,
  observedAt: number,
): PersonObservation[] {
  return result.landmarks.flatMap((landmarks, index) => {
    const observation = mapLandmarks(landmarks, observedAt, index);
    return observation === null ? [] : [observation];
  });
}

export function targetPoint(point: NormalizedPoint): NormalizedPoint {
  return { x: clamp01(point.x), y: clamp01(point.y) };
}
