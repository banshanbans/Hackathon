import { ArrowsOut, Repeat } from "@phosphor-icons/react";
import { useEffect, useRef, useState } from "react";
import {
  clientPointToNormalized,
  containRect,
  moveBox,
  resizeBox,
  type ContainRect,
  type NormalizedBox,
} from "../media/coordinates";

export function SelectionEditor({
  src,
  width,
  height,
  value,
  initialValue,
  onChange,
}: {
  src: string;
  width: number;
  height: number;
  value: NormalizedBox;
  initialValue: NormalizedBox;
  onChange: (value: NormalizedBox) => void;
}) {
  const stageRef = useRef<HTMLDivElement>(null);
  const [mediaRect, setMediaRect] = useState<ContainRect>({ x: 0, y: 0, width: 0, height: 0 });
  const [dragging, setDragging] = useState(false);

  useEffect(() => {
    const stage = stageRef.current;
    if (stage === null) {
      return;
    }
    const update = () => {
      const bounds = stage.getBoundingClientRect();
      setMediaRect(containRect(bounds.width, bounds.height, width, height));
    };
    update();
    if (typeof ResizeObserver === "undefined") {
      window.addEventListener("resize", update);
      return () => window.removeEventListener("resize", update);
    }
    const observer = new ResizeObserver(update);
    observer.observe(stage);
    return () => observer.disconnect();
  }, [height, width]);

  function updateFromPointer(clientX: number, clientY: number): void {
    const bounds = stageRef.current?.getBoundingClientRect();
    if (bounds === undefined) {
      return;
    }
    const point = clientPointToNormalized(
      clientX,
      clientY,
      bounds.left,
      bounds.top,
      mediaRect,
    );
    onChange(moveBox(value, point.x, point.y));
  }

  return (
    <div className="selection-editor">
      <div
        ref={stageRef}
        className="selection-stage"
        onPointerMove={(event) => {
          if (dragging) {
            updateFromPointer(event.clientX, event.clientY);
          }
        }}
        onPointerUp={(event) => {
          if (dragging) {
            updateFromPointer(event.clientX, event.clientY);
            setDragging(false);
          }
        }}
        onPointerCancel={() => setDragging(false)}
      >
        <img src={src} alt="待圈选的参考画面" draggable={false} />
        <button
          type="button"
          className="selection-box-button"
          aria-label="拖动人物选择框"
          style={{
            left: mediaRect.x + value.x * mediaRect.width,
            top: mediaRect.y + value.y * mediaRect.height,
            width: value.width * mediaRect.width,
            height: value.height * mediaRect.height,
          }}
          onPointerDown={(event) => {
            event.currentTarget.setPointerCapture(event.pointerId);
            setDragging(true);
            updateFromPointer(event.clientX, event.clientY);
          }}
          onKeyDown={(event) => {
            const delta = event.shiftKey ? 0.05 : 0.01;
            const centers: Record<string, [number, number]> = {
              ArrowLeft: [value.x + value.width / 2 - delta, value.y + value.height / 2],
              ArrowRight: [value.x + value.width / 2 + delta, value.y + value.height / 2],
              ArrowUp: [value.x + value.width / 2, value.y + value.height / 2 - delta],
              ArrowDown: [value.x + value.width / 2, value.y + value.height / 2 + delta],
            };
            const center = centers[event.key];
            if (center !== undefined) {
              event.preventDefault();
              onChange(moveBox(value, center[0], center[1]));
            }
          }}
        >
          <span>主角</span>
        </button>
      </div>
      <div className="selection-controls">
        <label>
          <ArrowsOut size={18} aria-hidden="true" />
          画面范围
          <input
            type="range"
            min="70"
            max="150"
            value={Math.round((value.width / initialValue.width) * 100)}
            aria-label="调整圈选框大小"
            onChange={(event) => {
              const targetScale = Number(event.target.value) / 100;
              onChange(resizeBox(value, (initialValue.width * targetScale) / value.width));
            }}
          />
        </label>
        <button type="button" onClick={() => onChange(initialValue)}>
          <Repeat size={17} aria-hidden="true" />
          重新定位
        </button>
      </div>
      <p className="selection-help">拖动橙色框，让人物完整落入画面。</p>
    </div>
  );
}
