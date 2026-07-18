import {
  createContext,
  type Dispatch,
  type ReactNode,
  useContext,
  useEffect,
  useReducer,
} from "react";
import type { UserConstraints } from "../apiClient";
import type { NormalizedBox } from "../media/coordinates";
import type { PreparedImage } from "../media/processing";

export type FlowMode = "original_replication" | "scene_adaptation";
export type ReferenceSource = "preset" | "upload";

export type FlowState = {
  mode: FlowMode;
  referenceSource: ReferenceSource;
  caseId: string | null;
  selectedBox: NormalizedBox;
  constraints: UserConstraints;
  consent: boolean;
  sessionId: string | null;
  executionMode: string | null;
  referenceMedia: PreparedImage | null;
  sceneMedia: PreparedImage | null;
  captureMedia: Partial<Record<1 | 2, PreparedImage>>;
};

type PersistedFlow = Pick<
  FlowState,
  | "mode"
  | "referenceSource"
  | "caseId"
  | "selectedBox"
  | "constraints"
  | "consent"
  | "sessionId"
  | "executionMode"
>;

type FlowAction =
  | { type: "patch"; value: Partial<FlowState> }
  | { type: "capture"; round: 1 | 2; value: PreparedImage | null }
  | { type: "reset" };

const STORAGE_KEY = "soloshot.w2.flow";

export const initialFlow: FlowState = {
  mode: "original_replication",
  referenceSource: "preset",
  caseId: null,
  selectedBox: { x: 0.25, y: 0.12, width: 0.5, height: 0.76 },
  constraints: {
    solo_traveler: true,
    tripod_available: false,
    has_luggage: false,
    notes: null,
  },
  consent: false,
  sessionId: null,
  executionMode: null,
  referenceMedia: null,
  sceneMedia: null,
  captureMedia: {},
};

function restore(): FlowState {
  if (typeof window === "undefined") {
    return initialFlow;
  }
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (raw === null) {
      return initialFlow;
    }
    const value = JSON.parse(raw) as Partial<PersistedFlow>;
    return {
      ...initialFlow,
      ...value,
      referenceMedia: null,
      sceneMedia: null,
      captureMedia: {},
    };
  } catch {
    return initialFlow;
  }
}

function revoke(media: PreparedImage | null | undefined): void {
  if (media !== null && media !== undefined && media.previewUrl.startsWith("blob:")) {
    URL.revokeObjectURL(media.previewUrl);
  }
}

function reducer(state: FlowState, action: FlowAction): FlowState {
  if (action.type === "reset") {
    revoke(state.referenceMedia);
    revoke(state.sceneMedia);
    revoke(state.captureMedia[1]);
    revoke(state.captureMedia[2]);
    return initialFlow;
  }
  if (action.type === "capture") {
    revoke(state.captureMedia[action.round]);
    const captureMedia = { ...state.captureMedia };
    if (action.value === null) {
      delete captureMedia[action.round];
    } else {
      captureMedia[action.round] = action.value;
    }
    return { ...state, captureMedia };
  }
  if (action.value.referenceMedia !== undefined) {
    revoke(state.referenceMedia);
  }
  if (action.value.sceneMedia !== undefined) {
    revoke(state.sceneMedia);
  }
  return { ...state, ...action.value };
}

type FlowContextValue = { state: FlowState; dispatch: Dispatch<FlowAction>; reset: () => void };
const FlowContext = createContext<FlowContextValue | null>(null);

export function FlowProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(reducer, undefined, restore);

  useEffect(() => {
    const persisted: PersistedFlow = {
      mode: state.mode,
      referenceSource: state.referenceSource,
      caseId: state.caseId,
      selectedBox: state.selectedBox,
      constraints: state.constraints,
      consent: state.consent,
      sessionId: state.sessionId,
      executionMode: state.executionMode,
    };
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(persisted));
  }, [state]);

  return (
    <FlowContext.Provider
      value={{
        state,
        dispatch,
        reset: () => {
          window.localStorage.removeItem(STORAGE_KEY);
          dispatch({ type: "reset" });
        },
      }}
    >
      {children}
    </FlowContext.Provider>
  );
}

export function useFlow(): FlowContextValue {
  const value = useContext(FlowContext);
  if (value === null) {
    throw new Error("useFlow must be used inside FlowProvider");
  }
  return value;
}
