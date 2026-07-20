// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import type { ShotPlan, SoloShotSession } from "./apiClient";
import { testImageDataset } from "./dataset";
import { presetCopy } from "./productCopy";

const selectedCase = testImageDataset.cases[0]!;
const analysis = {
  schema_version: "1.0",
  analysis_id: "ra_h5_test",
  reference_id: selectedCase.referenceId,
  person_count: selectedCase.expectedReference.personCount,
  target_layout: selectedCase.expectedReference.targetLayout,
  composition_notes: selectedCase.expectedReference.compositionNotes,
  safety_status: "safe",
  safety_warnings: [],
  confidence: selectedCase.expectedReference.confidence,
};
const plan: ShotPlan = {
  schema_version: "1.0",
  plan_id: "sp_h5_test",
  camera_height: "waist",
  camera_angle: "level",
  lens: "1x",
  capture_mode: "photo",
  phone_setup_instruction: "手机竖直固定在门廊正前方约三米处，镜头保持水平。",
  target_layout: selectedCase.expectedReference.targetLayout,
  action_script: [
    { sequence: 1, instruction: "站在门框中央，双脚自然错开。", duration_seconds: 2 },
    { sequence: 2, instruction: "举杯靠近嘴边，视线转向画面左侧。", duration_seconds: 2 },
  ],
  safety_notes: ["不要阻挡门口通行。"],
  h5_execution: { supported: true, instruction: "使用静态构图预览。", requires_realtime_alignment: false },
  ios_execution: { supported: true, instruction: "使用本地 Vision 对齐。", requires_realtime_alignment: true },
  confidence: 0.92,
};

function newSession(): SoloShotSession {
  const now = new Date().toISOString();
  return {
    schema_version: "1.0",
    session_id: "ss_h5_test",
    state: "created",
    source_channel: "demo_preset",
    mode: "original_replication",
    reference_asset: null,
    scene_asset_id: null,
    active_reference_analysis_id: null,
    user_constraints: {
      solo_traveler: true,
      tripod_available: false,
      has_luggage: false,
      notes: null,
    },
    selected_skills: [],
    shot_plan: null,
    capture_rounds: [],
    evaluation: null,
    evaluations: [],
    external_ai_consent_at: null,
    publish_package: null,
    analytics_context: { client: "h5", campaign: null },
    created_at: now,
    updated_at: now,
  };
}

function response(data: unknown, status = 200, mode: "fixture" | "live" | null = null): Response {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "X-Request-ID": "req_h5_test",
  };
  if (mode !== null) {
    headers["X-SoloShot-Execution-Mode"] = mode;
  }
  return new Response(JSON.stringify({ schema_version: "1.0", request_id: "req_h5_test", data }), {
    status,
    headers,
  });
}

function installFixtureApiMock() {
  let session = newSession();
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    if (url.pathname === "/api/v1/sessions" && init?.method === "POST") {
      return response(session, 201);
    }
    if (url.pathname === "/api/v1/references/analyze") {
      session = {
        ...session,
        state: "reference_ready",
        reference_asset: { ...selectedCase.referenceAsset, media_asset_id: null },
        active_reference_analysis_id: analysis.analysis_id,
      };
      return response(analysis, 202, "fixture");
    }
    if (url.pathname === "/api/v1/agent/runs") {
      session = {
        ...session,
        state: "shot_plan_ready",
        shot_plan: plan,
        selected_skills: [{ name: "shooting_plan", version: "1.0.0" }],
      };
      return response({ run_id: "run_h5_test", selected_skills: session.selected_skills }, 202, "fixture");
    }
    if (url.pathname === "/api/v1/sessions/ss_h5_test" && init?.method === "GET") {
      return response(session);
    }
    if (url.pathname === "/api/v1/captures") {
      const body = JSON.parse(String(init?.body)) as { round_index: 1 | 2; media_asset_id: string };
      const capture = {
        schema_version: "1.0" as const,
        capture_id: `cap_h5_round_${body.round_index}`,
        session_id: session.session_id,
        round_index: body.round_index,
        media_asset_id: body.media_asset_id,
        status: "ready" as const,
        selected_frame_id: null,
        created_at: new Date().toISOString(),
      };
      session = { ...session, state: "capturing", capture_rounds: [...session.capture_rounds, capture] };
      return response(capture, 201);
    }
    if (url.pathname === "/api/v1/evaluations") {
      const body = JSON.parse(String(init?.body)) as { capture_id: string };
      const first = body.capture_id.endsWith("_1");
      const evaluation = first
        ? {
            schema_version: "1.0" as const,
            evaluation_id: "eval_h5_round_1",
            capture_id: body.capture_id,
            issue_code: "person_too_small" as const,
            top_issue: "人物在门框中的占比偏小，姿态细节不够清楚。",
            next_instruction: "向前一步，其他动作保持不变",
            needs_retake: true,
            goal_satisfied: false,
            publish_readiness: 0.58,
            confidence: 0.86,
          }
        : {
            schema_version: "1.0" as const,
            evaluation_id: "eval_h5_round_2",
            capture_id: body.capture_id,
            needs_retake: false,
            goal_satisfied: true,
            publish_readiness: 0.9,
            confidence: 0.88,
          };
      session = {
        ...session,
        state: first ? "coaching" : "completed",
        evaluation,
        evaluations: [...session.evaluations, evaluation],
      };
      return response(evaluation, 202, "fixture");
    }
    if (url.pathname === "/api/v1/events/batch") {
      return response({ schema_version: "1.0", accepted_count: 1, duplicate_count: 0 }, 202);
    }
    throw new Error(`Unexpected request: ${url.pathname}`);
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() {
      return values.size;
    },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => values.delete(key),
    setItem: (key, value) => values.set(key, value),
  };
}

async function choosePreset(user: ReturnType<typeof userEvent.setup>): Promise<void> {
  await user.click(screen.getByRole("button", { name: "开始创作" }));
  const copy = presetCopy(selectedCase.caseId, selectedCase.title, selectedCase.subtitle);
  await user.click(screen.getByRole("button", { name: new RegExp(copy.title) }));
  await user.click(screen.getByRole("button", { name: "就是这个瞬间" }));
}

describe("W2 H5 flow", () => {
  beforeEach(() => {
    const storage = memoryStorage();
    Object.defineProperty(window, "localStorage", { configurable: true, value: storage });
    vi.stubGlobal("localStorage", storage);
    window.history.replaceState({}, "", "/");
    window.scrollTo = vi.fn();
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("routes every preset through the real selection page and labels Fixture honestly", async () => {
    const user = userEvent.setup();
    render(<App />);

    expect(screen.getAllByText("演示模式").length).toBeGreaterThan(0);
    await user.click(screen.getByRole("button", { name: "开始创作" }));
    for (const item of testImageDataset.cases) {
      const copy = presetCopy(item.caseId, item.title, item.subtitle);
      expect(screen.getByRole("button", { name: new RegExp(copy.title) })).toBeTruthy();
    }
    await user.click(screen.getByRole("button", { name: "返回上一步" }));
    await user.click(screen.getByRole("button", { name: "我的参考" }));
    await user.click(screen.getByRole("button", { name: "开始创作" }));
    expect(screen.getByLabelText("从相册选择").getAttribute("accept")).toContain("video/mp4");
  });

  it("completes the two-round Fixture flow and recovers the result from Session state", async () => {
    const user = userEvent.setup();
    installFixtureApiMock();
    const view = render(<App />);

    await choosePreset(user);
    await user.click(screen.getByRole("button", { name: "交给 SoloShot" }));
    expect(await screen.findByRole("heading", { name: "你的灵感，已经读懂" })).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "生成我的 ShotPlan" }));
    expect(await screen.findByRole("heading", { name: "你的专属 ShotPlan" })).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "继续在网页完成" }));
    await user.click(screen.getByRole("button", { name: "查看第一次建议" }));
    expect(await screen.findByRole("heading", { name: "人物比例偏小" })).toBeTruthy();
    expect(screen.getByText("以下结果来自精选样例。")).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "带着这条建议再拍一次" }));
    await user.click(screen.getByRole("button", { name: "查看第二次变化" }));
    await user.click(await screen.findByRole("button", { name: "查看我的作品" }));
    expect(await screen.findByRole("heading", { name: "一次调整，画面已经不同" })).toBeTruthy();
    expect(screen.getByText(/不生成虚构的前后对比照片/)).toBeTruthy();

    view.unmount();
    render(<App />);
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "一次调整，画面已经不同" })).toBeTruthy(),
    );
  });

  it("shows a recoverable error without switching execution mode to Fixture", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn().mockRejectedValue(new Error("offline"));
    vi.stubGlobal("fetch", fetchMock);
    render(<App />);

    await choosePreset(user);
    await user.click(screen.getByRole("button", { name: "交给 SoloShot" }));

    expect(await screen.findByText("暂时没有连上 SoloShot")).toBeTruthy();
    expect(screen.getAllByText("需要重试").length).toBeGreaterThan(0);
    expect(document.body.textContent).not.toMatch(/Fixture|Live|Fallback|Round|Session|Provider|W2|W5/);
    await user.click(screen.getByRole("button", { name: "再试一次" }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  });
});
