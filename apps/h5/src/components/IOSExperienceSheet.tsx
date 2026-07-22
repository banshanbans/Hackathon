import {
  Camera,
  CircleNotch,
  Crosshair,
  DeviceMobile,
  Footprints,
  ShieldCheck,
  X,
} from "@phosphor-icons/react";
import { useEffect, useRef, type RefObject } from "react";
import { createPortal } from "react-dom";

export type IOSExperienceState = "closed" | "open" | "creating" | "error";

type IOSExperienceSheetProps = {
  state: IOSExperienceState;
  hasExistingHandoff: boolean;
  triggerRef: RefObject<HTMLButtonElement | null>;
  onClose: () => void;
  onConfirm: () => void;
  onContinueOnWeb: () => void;
};

const focusableSelector = [
  "button:not([disabled])",
  "[href]",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  '[tabindex]:not([tabindex="-1"])',
].join(",");

export function IOSExperienceSheet({
  state,
  hasExistingHandoff,
  triggerRef,
  onClose,
  onConfirm,
  onContinueOnWeb,
}: IOSExperienceSheetProps) {
  const sheetRef = useRef<HTMLElement>(null);
  const titleRef = useRef<HTMLHeadingElement>(null);
  const isOpen = state !== "closed";
  const canClose = state === "open" || state === "error";

  useEffect(() => {
    if (!isOpen) {
      return;
    }
    const previousOverflow = document.body.style.overflow;
    const appShell = triggerRef.current?.closest<HTMLElement>(".app-shell") ?? null;
    const previousAriaHidden = appShell?.getAttribute("aria-hidden") ?? null;
    const previouslyInert = appShell?.hasAttribute("inert") ?? false;
    document.body.style.overflow = "hidden";
    appShell?.setAttribute("aria-hidden", "true");
    appShell?.setAttribute("inert", "");
    const frame = window.requestAnimationFrame(() => titleRef.current?.focus());
    return () => {
      window.cancelAnimationFrame(frame);
      document.body.style.overflow = previousOverflow;
      if (previousAriaHidden === null) {
        appShell?.removeAttribute("aria-hidden");
      } else {
        appShell?.setAttribute("aria-hidden", previousAriaHidden);
      }
      if (!previouslyInert) {
        appShell?.removeAttribute("inert");
      }
      window.requestAnimationFrame(() => triggerRef.current?.focus());
    };
  }, [isOpen, triggerRef]);

  useEffect(() => {
    if (!isOpen) {
      return;
    }
    function handleKeyDown(event: KeyboardEvent): void {
      if (event.key === "Escape") {
        if (canClose) {
          event.preventDefault();
          onClose();
        }
        return;
      }
      if (event.key !== "Tab" || sheetRef.current === null) {
        return;
      }
      const focusable = [...sheetRef.current.querySelectorAll<HTMLElement>(focusableSelector)];
      if (focusable.length === 0) {
        event.preventDefault();
        titleRef.current?.focus();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const currentIndex = focusable.indexOf(document.activeElement as HTMLElement);
      if (currentIndex === -1) {
        event.preventDefault();
        (event.shiftKey ? last : first)?.focus();
      } else if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    }
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [canClose, isOpen, onClose]);

  if (!isOpen) {
    return null;
  }

  return createPortal(
    <div
      className="ios-experience-backdrop"
      onMouseDown={(event) => {
        if (canClose && event.target === event.currentTarget) {
          onClose();
        }
      }}
    >
      <section
        ref={sheetRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="ios-experience-title"
        aria-describedby="ios-experience-description"
        className="ios-experience-sheet"
      >
        <div className="ios-experience-handle" aria-hidden="true" />
        <button
          type="button"
          className="ios-experience-close"
          aria-label="关闭 iPhone 现场陪拍说明"
          disabled={!canClose}
          onClick={onClose}
        >
          <X size={20} aria-hidden="true" />
        </button>

        <div className="ios-experience-content">
          <div className="ios-experience-heading">
            <span className="ios-experience-icon" aria-hidden="true">
              <DeviceMobile size={27} weight="duotone" />
            </span>
            <span className="ios-experience-badge">体验我们的全部功能</span>
          </div>

          <h2
            id="ios-experience-title"
            ref={titleRef}
            tabIndex={-1}
            aria-label="来游园会，用 iPhone 体验完整陪拍"
          >
            来游园会，用 iPhone<br />体验完整陪拍
          </h2>
          <div id="ios-experience-description" className="ios-experience-description">
            <p>
              为了更完整地展现 SoloShot 的能力，我们设计了专门适配 iPhone 相机的 iOS App。目前为游园会现场演示版本，暂未通过 App Store 分发。
            </p>
            <p>
              你可以继续在网页端轻量体验，也可以生成现场体验码，把同一个 ShotPlan 接力到游园会现场的 iPhone。
            </p>
            <p>
              到了现场，iPhone 会接过同一个任务，实时判断你的站位、距离和动作，在你移动时持续陪你完成拍摄。未来还计划支持与 Apple Watch 协作。
            </p>
          </div>

          <div className="ios-experience-features">
            <ExperienceFeature
              icon={<Crosshair size={22} weight="duotone" />}
              title="实时看懂你的位置"
              description="判断左右、远近，以及人物是否完整入镜。"
            />
            <ExperienceFeature
              icon={<Footprints size={22} weight="duotone" />}
              title="边走边获得引导"
              description="通过目标轮廓、文字、语音和触觉，告诉你下一步怎么调整。"
            />
            <ExperienceFeature
              icon={<Camera size={22} weight="duotone" />}
              title="对齐后自动完成拍摄"
              description="自动倒计时录制并推荐候选画面。"
            />
          </div>

          <div className="ios-experience-local-note">
            <ShieldCheck size={21} weight="fill" aria-hidden="true" />
            <span>核心对齐在 iPhone 本地运行，现场网络不稳定也能继续拍摄。</span>
          </div>
        </div>

        <div className="ios-experience-actions">
          {state === "error" ? (
            <p className="ios-experience-error" role="alert">
              现场任务暂时没有准备好，请检查网络后重试。
            </p>
          ) : null}
          <button
            type="button"
            className="primary-button"
            disabled={state === "creating"}
            aria-busy={state === "creating"}
            onClick={onConfirm}
          >
            {state === "creating" ? (
              <><CircleNotch className="spin" size={20} aria-hidden="true" /> 正在准备任务…</>
            ) : state === "error" ? (
              "重新生成体验码"
            ) : hasExistingHandoff ? (
              "查看现场体验码"
            ) : (
              "生成现场体验码"
            )}
          </button>
          <button
            type="button"
            className="secondary-button"
            disabled={state === "creating"}
            onClick={onContinueOnWeb}
          >
            继续在网页轻量完成
          </button>
        </div>
      </section>
    </div>,
    document.body,
  );
}

function ExperienceFeature({
  icon,
  title,
  description,
}: {
  icon: React.ReactNode;
  title: string;
  description: string;
}) {
  return (
    <div className="ios-experience-feature">
      <span aria-hidden="true">{icon}</span>
      <div>
        <strong>{title}</strong>
        <p>{description}</p>
      </div>
    </div>
  );
}
