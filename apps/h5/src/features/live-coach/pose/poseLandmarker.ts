import {
  FilesetResolver,
  ImageSegmenter,
  PoseLandmarker,
  type MPMask,
  type NormalizedLandmark,
} from "@mediapipe/tasks-vision";
import type { NormalizedRect, PersonObservation } from "../domain/alignmentModels";
import { intersectionOverUnion } from "../domain/alignmentModels";
import {
  binaryMaskFromProbabilities,
  contourFromMask,
  type BinarySilhouetteMask,
  type SilhouetteContour,
} from "../domain/silhouette";
import { observationsFromMediaPipe } from "./mediapipeAdapter";

export const MEDIAPIPE_RUNTIME_VERSION = "0.10.35";
export const MEDIAPIPE_WASM_PATH = `/mediapipe/${MEDIAPIPE_RUNTIME_VERSION}/wasm`;
export const POSE_MODEL_PATH = "/models/mediapipe/pose-landmarker-lite-v1.task";
export const PERSON_SEGMENTER_MODEL_PATH =
  "/models/mediapipe/selfie-segmenter-float16-v1.tflite";

export type PoseFrameResult = {
  landmarks: NormalizedLandmark[][];
  masks: Array<BinarySilhouetteMask | null>;
};

export type PoseRuntime = {
  detect(
    source: HTMLVideoElement,
    timestamp: number,
    includeMasks: boolean,
  ): PoseFrameResult;
  close(): void;
};

export type ReferenceSilhouetteStatus =
  | "ready"
  | "no_person"
  | "multiple_people"
  | "partial_person"
  | "extraction_failed";

export type ReferenceSilhouetteResult = {
  status: ReferenceSilhouetteStatus;
  contour: SilhouetteContour | null;
};

export type PreparedPoseRuntime = {
  runtime: PoseRuntime;
  reference: ReferenceSilhouetteResult;
};

function copyMask(mask: MPMask): BinarySilhouetteMask | null {
  // Only copied ImageSegmenter results are consumed. Callback-owned WebGL
  // textures must never escape their frame or be converted after the callback.
  if (!mask.hasFloat32Array()) return null;
  return binaryMaskFromProbabilities(
    new Float32Array(mask.getAsFloat32Array()),
    mask.width,
    mask.height,
  );
}

function wrapRuntime(landmarker: PoseLandmarker, segmenter: ImageSegmenter): PoseRuntime {
  return {
    detect: (video, timestamp, includeMasks) => {
      if (includeMasks) {
        const result = segmenter.segmentForVideo(video, timestamp);
        try {
          let landmarks: NormalizedLandmark[][] = [];
          landmarker.detectForVideo(video, timestamp, (poseResult) => {
            landmarks = poseResult.landmarks;
          });
          return {
            landmarks,
            masks: [result.confidenceMasks?.[0] === undefined
              ? null
              : copyMask(result.confidenceMasks[0])],
          };
        } finally {
          result.close();
        }
      }
      let frame: PoseFrameResult = { landmarks: [], masks: [] };
      landmarker.detectForVideo(video, timestamp, (result) => {
        frame = {
          landmarks: result.landmarks,
          masks: [],
        };
      });
      return frame;
    },
    close: () => {
      landmarker.close();
      segmenter.close();
    },
  };
}

async function createTasks(runningMode: "IMAGE" | "VIDEO"): Promise<{
  landmarker: PoseLandmarker;
  segmenter: ImageSegmenter;
}> {
  const files = await FilesetResolver.forVisionTasks(MEDIAPIPE_WASM_PATH);
  const landmarker = await PoseLandmarker.createFromOptions(files, {
    baseOptions: { modelAssetPath: POSE_MODEL_PATH, delegate: "CPU" },
    runningMode,
    numPoses: 2,
    minPoseDetectionConfidence: 0.45,
    minPosePresenceConfidence: 0.45,
    minTrackingConfidence: 0.45,
    outputSegmentationMasks: false,
  });
  try {
    const segmenter = await ImageSegmenter.createFromOptions(files, {
      baseOptions: { modelAssetPath: PERSON_SEGMENTER_MODEL_PATH, delegate: "CPU" },
      runningMode,
      outputConfidenceMasks: true,
      outputCategoryMask: false,
    });
    return { landmarker, segmenter };
  } catch (error) {
    landmarker.close();
    throw error;
  }
}

export async function createPoseRuntime(): Promise<PoseRuntime> {
  const { landmarker, segmenter } = await createTasks("VIDEO");
  return wrapRuntime(landmarker, segmenter);
}

function selectReferencePose(
  landmarks: NormalizedLandmark[][],
  selectedBox: NormalizedRect,
): PersonObservation | null {
  const observations = observationsFromMediaPipe({ landmarks }, performance.now());
  if (observations.length === 0) return null;
  const selected = observations.reduce((best, observation) =>
    intersectionOverUnion(observation.boundingBox, selectedBox) >
    intersectionOverUnion(best.boundingBox, selectedBox)
      ? observation
      : best,
  );
  return selected;
}

export function isPartialReferencePerson(observation: PersonObservation): boolean {
  const edgeMargin = 0.01;
  const { boundingBox, joints } = observation;
  const touchesEdge =
    boundingBox.x <= edgeMargin ||
    boundingBox.y <= edgeMargin ||
    boundingBox.x + boundingBox.width >= 1 - edgeMargin ||
    boundingBox.y + boundingBox.height >= 1 - edgeMargin;
  const headVisible = (joints.nose?.confidence ?? 0) >= 0.2 || (joints.neck?.confidence ?? 0) >= 0.2;
  const feetVisible =
    (joints.leftAnkle?.confidence ?? 0) >= 0.2 &&
    (joints.rightAnkle?.confidence ?? 0) >= 0.2;
  return touchesEdge || !headVisible || !feetVisible;
}

export async function createPreparedPoseRuntime(
  image: HTMLImageElement,
  selectedBox: NormalizedRect,
): Promise<PreparedPoseRuntime> {
  const { landmarker, segmenter } = await createTasks("IMAGE");
  let landmarks: NormalizedLandmark[][] = [];
  let masks: Array<BinarySilhouetteMask | null> = [];
  try {
    const result = landmarker.detect(image);
    try {
      landmarks = result.landmarks;
    } finally {
      result.close();
    }
    const segmentation = segmenter.segment(image);
    try {
      masks = [segmentation.confidenceMasks?.[0] === undefined
        ? null
        : copyMask(segmentation.confidenceMasks[0])];
    } finally {
      segmentation.close();
    }
    const observations = observationsFromMediaPipe({ landmarks }, performance.now());
    const selected = selectReferencePose(landmarks, selectedBox);
    let reference: ReferenceSilhouetteResult;
    if (observations.length > 1) {
      reference = { status: "multiple_people", contour: null };
    } else if (selected === null) {
      reference = { status: "no_person", contour: null };
    } else if (isPartialReferencePerson(selected)) {
      reference = { status: "partial_person", contour: null };
    } else {
      const selectedMask = masks[0] ?? null;
      const contour = selectedMask === null ? null : contourFromMask(selectedMask);
      reference = contour === null
        ? { status: "extraction_failed", contour: null }
        : { status: "ready", contour };
    }
    await landmarker.setOptions({ runningMode: "VIDEO" });
    await segmenter.setOptions({ runningMode: "VIDEO" });
    return { runtime: wrapRuntime(landmarker, segmenter), reference };
  } catch (error) {
    landmarker.close();
    segmenter.close();
    throw error;
  }
}
