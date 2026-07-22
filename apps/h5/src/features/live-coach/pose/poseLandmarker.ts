import { FilesetResolver, PoseLandmarker, type PoseLandmarkerResult } from "@mediapipe/tasks-vision";

export const MEDIAPIPE_RUNTIME_VERSION = "0.10.35";
export const MEDIAPIPE_WASM_PATH = `/mediapipe/${MEDIAPIPE_RUNTIME_VERSION}/wasm`;
export const POSE_MODEL_PATH = "/models/mediapipe/pose-landmarker-lite-v1.task";

export type PoseRuntime = {
  detect(video: HTMLVideoElement, timestamp: number): PoseLandmarkerResult;
  close(): void;
};

export async function createPoseRuntime(): Promise<PoseRuntime> {
  const files = await FilesetResolver.forVisionTasks(MEDIAPIPE_WASM_PATH);
  const landmarker = await PoseLandmarker.createFromOptions(files, {
    baseOptions: { modelAssetPath: POSE_MODEL_PATH },
    runningMode: "VIDEO",
    numPoses: 2,
    minPoseDetectionConfidence: 0.45,
    minPosePresenceConfidence: 0.45,
    minTrackingConfidence: 0.45,
    outputSegmentationMasks: false,
  });
  return {
    detect: (video, timestamp) => landmarker.detectForVideo(video, timestamp),
    close: () => landmarker.close(),
  };
}
