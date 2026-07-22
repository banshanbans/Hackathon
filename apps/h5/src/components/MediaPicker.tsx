import { Camera, FilmStrip, ImageSquare, Repeat, UploadSimple } from "@phosphor-icons/react";
import { type ReactNode, useEffect, useState } from "react";
import {
  extractVideoFrame,
  inspectVideo,
  normalizeImage,
  type PreparedImage,
} from "../media/processing";

function messageFor(error: unknown): string {
  const code = error instanceof Error ? error.message : "UNSUPPORTED_MEDIA";
  const messages: Record<string, string> = {
    MEDIA_TOO_LARGE: "这份素材有点大，请换一张照片或更短的视频。",
    VIDEO_TOO_LONG: "这段视频有点长，请选择 30 秒内的片段。",
    IMAGE_ENCODE_FAILED: "这张画面没有准备好，请换一张再试。",
    UNSUPPORTED_MEDIA: "这份素材暂时无法使用，请换一张照片或短视频。",
  };
  return messages[code] ?? "这张画面没有准备好，请重新选择。";
}

export function MediaPicker({
  value,
  onChange,
  allowVideo = true,
  title = "加入这张画面",
  disabled = false,
  overlay = null,
}: {
  value: PreparedImage | null;
  onChange: (value: PreparedImage) => void;
  allowVideo?: boolean;
  title?: string;
  disabled?: boolean;
  overlay?: ReactNode;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [video, setVideo] = useState<{ file: File; url: string; currentTime: number } | null>(null);
  const videoUrl = video?.url;

  useEffect(() => {
    return () => {
      if (videoUrl !== undefined) {
        URL.revokeObjectURL(videoUrl);
      }
    };
  }, [videoUrl]);

  async function choose(file: File | undefined): Promise<void> {
    if (file === undefined) {
      return;
    }
    setError(null);
    setBusy(true);
    try {
      if (file.type.startsWith("video/")) {
        if (!allowVideo) {
          throw new Error("UNSUPPORTED_MEDIA");
        }
        await inspectVideo(file);
        if (video !== null) {
          URL.revokeObjectURL(video.url);
        }
        setVideo({ file, url: URL.createObjectURL(file), currentTime: 0 });
      } else {
        const prepared = await normalizeImage(file);
        setVideo(null);
        onChange(prepared);
      }
    } catch (caught) {
      setError(messageFor(caught));
    } finally {
      setBusy(false);
    }
  }

  async function useFrame(): Promise<void> {
    if (video === null) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      onChange(await extractVideoFrame(video.file, video.currentTime));
      URL.revokeObjectURL(video.url);
      setVideo(null);
    } catch (caught) {
      setError(messageFor(caught));
    } finally {
      setBusy(false);
    }
  }

  const accept = allowVideo
    ? "image/jpeg,image/png,image/webp,video/mp4,video/quicktime"
    : "image/jpeg,image/png,image/webp";

  return (
    <div className="media-picker">
      <div className="media-picker-heading">
        <strong>{title}</strong>
        {value !== null ? <span className="ready-mark">已选好</span> : null}
      </div>

      {value !== null ? (
        <div
          className="local-preview"
          style={{ aspectRatio: `${value.width} / ${value.height}` }}
        >
          <img src={value.previewUrl} alt="已选择的本地画面" />
          {overlay}
          <span>
            {value.mediaType === "video_frame" ? "视频中的这一帧" : "已选择的照片"}
          </span>
        </div>
      ) : null}

      {video !== null ? (
        <div className="video-frame-picker">
          <video
            src={video.url}
            controls
            playsInline
            muted
            onTimeUpdate={(event) =>
              setVideo((current) =>
                current === null
                  ? null
                  : { ...current, currentTime: event.currentTarget.currentTime },
              )
            }
          />
          <button type="button" onClick={useFrame} disabled={busy}>
            <FilmStrip size={18} aria-hidden="true" />
            使用这一帧
          </button>
        </div>
      ) : null}

      <div className="picker-actions">
        <label aria-disabled={disabled}>
          <Camera size={19} aria-hidden="true" />
          拍下此刻
          <input
            type="file"
            accept="image/jpeg,image/png,image/webp"
            capture="environment"
            disabled={disabled}
            onChange={(event) => void choose(event.target.files?.[0])}
          />
        </label>
        <label aria-disabled={disabled}>
          <UploadSimple size={19} aria-hidden="true" />
          从相册选择
          <input
            type="file"
            accept={accept}
            disabled={disabled}
            onChange={(event) => void choose(event.target.files?.[0])}
          />
        </label>
      </div>

      {busy ? (
        <p className="picker-status" role="status">
          <ImageSquare size={18} aria-hidden="true" /> 正在准备这张画面…
        </p>
      ) : null}
      {error !== null ? (
        <p className="picker-error" role="alert">
          <Repeat size={18} aria-hidden="true" /> {error}
        </p>
      ) : null}
    </div>
  );
}

export function UploadProgress({
  value,
  onCancel,
  label = "正在保存这张画面",
}: {
  value: number;
  onCancel: () => void;
  label?: string;
}) {
  return (
    <div className="upload-progress" role="status" aria-live="polite">
      <span>
        <strong>{label}</strong>
        <small>{value}%</small>
      </span>
      <div aria-label={`上传进度 ${value}%`}>
        <span style={{ width: `${value}%` }} />
      </div>
      <button type="button" onClick={onCancel}>
        取消
      </button>
    </div>
  );
}
