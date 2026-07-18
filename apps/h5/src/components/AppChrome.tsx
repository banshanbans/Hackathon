import { ArrowLeft, Camera } from "@phosphor-icons/react";
import type { ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import type { ExecutionMode } from "../apiClient";
import { useFlow } from "../flow/FlowProvider";

const modeLabels: Record<ExecutionMode, string> = {
  fixture: "Fixture",
  mock: "Fixture",
  live: "Live",
  cache: "Cache",
  fallback: "Fallback",
  error: "Error",
};

export function ExecutionBadge({ mode }: { mode: ExecutionMode | null }) {
  const current = mode ?? "error";
  return <span className={`execution-badge execution-${current}`}>{modeLabels[current]}</span>;
}

export function BrandHeader() {
  const navigate = useNavigate();
  const { state, reset } = useFlow();
  const inferredMode: ExecutionMode =
    (state.executionMode as ExecutionMode | null) ??
    (state.referenceSource === "preset" && state.mode === "original_replication"
      ? "fixture"
      : "live");
  return (
    <header className="brand-header">
      <button
        className="brand"
        type="button"
        onClick={() => {
          reset();
          navigate("/");
        }}
        aria-label="返回 SoloShot 首页"
      >
        <span className="brand-mark" aria-hidden="true">
          <Camera weight="fill" size={20} />
        </span>
        <span>SoloShot AI</span>
      </button>
      <ExecutionBadge mode={inferredMode} />
    </header>
  );
}

export function PageHeader({ title, backTo }: { title: string; backTo: string }) {
  const navigate = useNavigate();
  return (
    <div className="page-header">
      <button type="button" onClick={() => navigate(backTo)} aria-label="返回上一步">
        <ArrowLeft size={22} aria-hidden="true" />
      </button>
      <h1>{title}</h1>
      <span aria-hidden="true" />
    </div>
  );
}

export function StateNotice({
  mode,
  children,
}: {
  mode: ExecutionMode;
  children: ReactNode;
}) {
  return (
    <div className={`state-notice state-${mode}`} role="status">
      <ExecutionBadge mode={mode} />
      <span>{children}</span>
    </div>
  );
}
