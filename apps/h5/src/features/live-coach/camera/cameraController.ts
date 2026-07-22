export type CameraCheck = {
  secureContext: boolean;
  mediaDevices: boolean;
  supported: boolean;
};

export function checkCameraSupport(): CameraCheck {
  const secureContext = window.isSecureContext;
  const mediaDevices = navigator.mediaDevices?.getUserMedia !== undefined;
  return { secureContext, mediaDevices, supported: secureContext && mediaDevices };
}

export class CameraController {
  private stream: MediaStream | null = null;

  async start(video: HTMLVideoElement): Promise<MediaTrackSettings> {
    this.stop();
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        facingMode: { ideal: "environment" },
        width: { ideal: 720 },
        height: { ideal: 1280 },
        aspectRatio: { ideal: 9 / 16 },
      },
    });
    this.stream = stream;
    video.srcObject = stream;
    video.muted = true;
    video.playsInline = true;
    await video.play();
    const track = stream.getVideoTracks()[0];
    if (track === undefined) {
      this.stop();
      throw new Error("CAMERA_TRACK_MISSING");
    }
    return track.getSettings();
  }

  stop(): void {
    this.stream?.getTracks().forEach((track) => track.stop());
    this.stream = null;
  }
}
