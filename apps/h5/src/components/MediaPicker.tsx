import { Camera, FilmStrip, ImageSquare, Repeat, UploadSimple } from "@phosphor-icons/react";
import { useEffect, useState } from "react";
import {
  extractVideoFrame,
  inspectVideo,
  normalizeImage,
  type PreparedImage,
} from "../media/processing";

function messageFor(error: unknown): string {
  const code = error instanceof Error ? error.message : "UNSUPPORTED_MEDIA";
  const messages: Record<string, string> = {
    MEDIA_TOO_LARGE: "文件过大：图片上传结果需小于 8MB，视频需小于 100MB。",
    VIDEO_TOO_LONG: "视频最长支持 30 秒，请重新选择。",
    IMAGE_ENCODE_FAILED: "图片处理失败，请换一张图片重试。",
    UNSUPPORTED_MEDIA: "无法读取这个文件，请选择 JPEG、PNG、WebP 或短视频。",
  };
  return messages[code] ?? "媒体处理失败，请重新选择。";
}

export function MediaPicker({
  value,
  onChange,
  allowVideo = true,
  title = "添加画面",
}: {
  value: PreparedImage | null;
  onChange: (value: PreparedImage) => void;
  allowVideo?: boolean;
  title?: string;
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
        <span>
          <strong>{title}</strong>
          <small>图片自动校正方向并压缩至最长边 2048px</small>
        </span>
        {value !== null ? <span className="ready-mark">已就绪</span> : null}
      </div>

      {value !== null ? (
        <div className="local-preview">
          <img src={value.previewUrl} alt="已选择的本地画面" />
          <span>
            {value.width} × {value.height} · {value.mediaType === "video_frame" ? "视频帧" : "图片"}
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
            使用当前暂停画面
          </button>
        </div>
      ) : null}

      <div className="picker-actions">
        <label>
          <Camera size={19} aria-hidden="true" />
          拍照
          <input
            type="file"
            accept="image/jpeg,image/png,image/webp"
            capture="environment"
            onChange={(event) => void choose(event.target.files?.[0])}
          />
        </label>
        <label>
          <UploadSimple size={19} aria-hidden="true" />
          从相册选择
          <input
            type="file"
            accept={accept}
            onChange={(event) => void choose(event.target.files?.[0])}
          />
        </label>
      </div>

      {busy ? (
        <p className="picker-status" role="status">
          <ImageSquare size={18} aria-hidden="true" /> 正在处理画面…
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
}: {
  value: number;
  onCancel: () => void;
}) {
  return (
    <div className="upload-progress" role="status" aria-live="polite">
      <span>
        <strong>正在安全上传</strong>
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
