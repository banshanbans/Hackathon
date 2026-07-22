import type { PreparedImage } from "../../../media/processing";
import type { AlignmentDecision } from "./alignmentModels";

export type CaptureCandidate = {
  id: string;
  capturedAt: number;
  image: PreparedImage;
  localScore: number;
  reasons: string[];
  metrics: {
    completeFraming: number;
    targetPositionMatch: number;
    personScaleMatch: number;
    sharpness: number;
    supportedPoseMatch: number | null;
    personCount: number;
    headAndFeetVisible: boolean;
    averageConfidence: number;
  };
};

export function scoreCandidate(
  id: string,
  image: PreparedImage,
  capturedAt: number,
  decision: AlignmentDecision | null,
  sharpness: number,
): CaptureCandidate {
  const person = decision?.selectedPerson ?? null;
  const metrics = {
    completeFraming: decision?.fullBodyVisible === true ? 1 : person === null ? 0 : 0.45,
    targetPositionMatch:
      decision === null
        ? 0
        : decision.positionStatus === "centered"
          ? Math.max(0, decision.overlapRatio)
          : decision.stabilityScore * 0.65,
    personScaleMatch:
      decision === null
        ? 0
        : decision.scaleStatus === "correct"
          ? Math.max(0.7, decision.stabilityScore)
          : decision.stabilityScore * 0.65,
    sharpness,
    supportedPoseMatch:
      decision?.poseCheckSupported === true ? (decision.poseStatus === "acceptable" ? 1 : 0.25) : null,
    personCount: decision === null ? 0 : decision.multiplePeople ? 2 : decision.personDetected ? 1 : 0,
    headAndFeetVisible: decision?.fullBodyVisible ?? false,
    averageConfidence: person?.confidence ?? 0,
  };
  let weighted =
    metrics.completeFraming * 0.3 +
    metrics.targetPositionMatch * 0.25 +
    metrics.personScaleMatch * 0.2 +
    metrics.sharpness * 0.15;
  let totalWeight = 0.9;
  if (metrics.supportedPoseMatch !== null) {
    weighted += metrics.supportedPoseMatch * 0.1;
    totalWeight = 1;
  }
  let localScore = weighted / totalWeight;
  if (metrics.personCount !== 1) localScore *= 0.35;
  if (!metrics.headAndFeetVisible) localScore *= 0.55;
  if (metrics.averageConfidence < 0.55) localScore *= 0.65;
  const reasons: string[] = [];
  if (metrics.personCount > 1) reasons.push("画面里出现了其他人");
  else if (metrics.personCount === 0) reasons.push("人物没有稳定入镜");
  if (!metrics.headAndFeetVisible) reasons.push("画面边缘裁到了人物");
  if (metrics.sharpness >= 0.72) reasons.push("这一张更清晰");
  if (metrics.targetPositionMatch >= 0.72) reasons.push("站位更接近 ShotPlan");
  if (metrics.personScaleMatch >= 0.72) reasons.push("人物比例更自然");
  if (metrics.supportedPoseMatch === null) reasons.push("动作使用构图模式判断");
  if (reasons.length === 0) reasons.push("整体画面更稳定");
  return {
    id,
    capturedAt,
    image,
    localScore: Math.min(1, Math.max(0, localScore)),
    reasons: reasons.slice(0, 2),
    metrics,
  };
}

export function rankCandidates(candidates: CaptureCandidate[]): CaptureCandidate[] {
  return [...candidates].sort(
    (left, right) => right.localScore - left.localScore || left.capturedAt - right.capturedAt,
  );
}
