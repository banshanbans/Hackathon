import { expect, test, type Page, type Route } from "@playwright/test";
import { resolve } from "node:path";

const referenceId = "ref_doorway_coffee_fullbody";
const layout = {
  center_x: 0.49,
  center_y: 0.7,
  width: 0.3,
  height: 0.56,
  head_point: { x: 0.49, y: 0.42 },
  foot_line_y: 0.98,
  body_direction: "slightly_left",
  pose_template: "standing_coffee_full_body",
};
const plan = {
  schema_version: "1.0",
  plan_id: "sp_e2e",
  camera_height: "waist",
  camera_angle: "level",
  lens: "1x",
  capture_mode: "photo",
  phone_setup_instruction: "手机竖直固定在门廊正前方约三米处，镜头保持水平。",
  target_layout: layout,
  action_script: [
    { sequence: 1, instruction: "站在门框中央，双脚自然错开。", duration_seconds: 2 },
    { sequence: 2, instruction: "举杯靠近嘴边，视线转向画面左侧。", duration_seconds: 2 },
  ],
  safety_notes: ["不要阻挡门口通行。"],
  h5_execution: { supported: true, instruction: "使用静态构图预览。", requires_realtime_alignment: false },
  ios_execution: { supported: true, instruction: "使用本地 Vision 对齐。", requires_realtime_alignment: true },
  confidence: 0.92,
};

const testImagePath = resolve(
  import.meta.dirname,
  "../../public/presets/test-image-v1/doorway_coffee_fullbody-detail.webp",
);

type Json = Record<string, unknown>;

async function fulfill(route: Route, data: unknown, status = 200, mode?: "fixture" | "live") {
  await route.fulfill({
    status,
    contentType: "application/json",
    headers: {
      "X-Request-ID": "req_e2e",
      ...(mode === undefined ? {} : { "X-SoloShot-Execution-Mode": mode }),
    },
    body: JSON.stringify({ schema_version: "1.0", request_id: "req_e2e", data }),
  });
}

async function fulfillError(route: Route, code: string, status: number) {
  await route.fulfill({
    status,
    contentType: "application/json",
    body: JSON.stringify({
      schema_version: "1.0",
      request_id: "req_e2e",
      error: { code, message: "safe test error", recoverable: true },
    }),
  });
}

async function installApiRoutes(
  page: Page,
  options: {
    adaptFailures?: number;
    uploadDelayMs?: number;
    adaptDelayMs?: number;
    planDelayMs?: number;
  } = {},
) {
  const now = new Date().toISOString();
  let counter = 0;
  let adaptRequestCount = 0;
  let remainingAdaptFailures = options.adaptFailures ?? 0;
  let session: Json = {};
  const media = new Map<string, Json>();
  let handoffStatus: "created" | "claimed" | "completed" = "created";
  const handoff = () => ({
    schema_version: "1.0",
    handoff_id: "handoff_e2e",
    code: "294816",
    status: handoffStatus,
    mode: "original_replication",
    created_at: now,
    expires_at: new Date(Date.now() + 600_000).toISOString(),
    claimed_at: handoffStatus === "created" ? null : now,
    completed_at: handoffStatus === "completed" ? now : null,
  });

  await page.route("**/upload/**", async (route) => {
    if ((options.uploadDelayMs ?? 0) > 0) {
      await new Promise((resolveDelay) => setTimeout(resolveDelay, options.uploadDelayMs));
    }
    await route.fulfill({ status: 200, body: "" });
  });
  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const body = request.postData() === null ? {} : (request.postDataJSON() as Json);
    if (url.pathname === "/api/v1/handoffs" && request.method() === "POST") {
      session = { ...session, state: "handoff_ready" };
      await fulfill(route, {
        schema_version: "1.0",
        handoff: handoff(),
        management_token: "management-token-e2e-management-token",
        qr_payload: "https://handoff.example.test/handoff/294816",
      }, 201);
      return;
    }
    if (url.pathname === "/api/v1/handoffs/294816/claim") {
      handoffStatus = "claimed";
      await fulfill(route, {
        schema_version: "1.0",
        handoff: handoff(),
        session,
        claim_token: "claim-token-e2e-claim-token-e2e",
        reference_access: null,
      });
      return;
    }
    if (url.pathname === "/api/v1/handoffs/294816/complete") {
      handoffStatus = "completed";
      await fulfill(route, handoff());
      return;
    }
    if (url.pathname === "/api/v1/handoffs/294816" && request.method() === "GET") {
      await fulfill(route, handoff());
      return;
    }
    if (url.pathname === "/api/v1/sessions" && request.method() === "POST") {
      session = {
        schema_version: "1.0",
        session_id: "ss_e2e",
        state: "created",
        source_channel: body.source_channel,
        mode: body.mode,
        reference_asset: null,
        scene_asset_id: null,
        active_reference_analysis_id: null,
        user_constraints: body.user_constraints,
        selected_skills: [],
        shot_plan: null,
        capture_rounds: [],
        evaluation: null,
        evaluations: [],
        external_ai_consent_at: body.external_ai_consent === true ? now : null,
        publish_package: null,
        analytics_context: { client: "h5", campaign: null },
        created_at: now,
        updated_at: now,
      };
      await fulfill(route, session, 201);
      return;
    }
    if (url.pathname === "/api/v1/media/uploads") {
      counter += 1;
      const id = `media_e2e_${counter}`;
      const asset = {
        schema_version: "1.0",
        media_asset_id: id,
        session_id: "ss_e2e",
        purpose: body.purpose,
        content_type: "image/jpeg",
        byte_size: body.byte_size,
        sha256: body.sha256,
        status: "pending_upload",
        width: null,
        height: null,
        expires_at: new Date(Date.now() + 86_400_000).toISOString(),
        created_at: now,
      };
      media.set(id, asset);
      await fulfill(
        route,
        {
          schema_version: "1.0",
          asset,
          upload_url: `http://127.0.0.1:4173/upload/${id}`,
          upload_headers: { "Content-Type": "image/jpeg" },
          upload_expires_at: new Date(Date.now() + 600_000).toISOString(),
        },
        201,
      );
      return;
    }
    if (url.pathname.endsWith("/complete")) {
      const id = url.pathname.split("/").at(-2)!;
      const ready = { ...media.get(id), status: "ready", width: 2, height: 2 };
      media.set(id, ready);
      await fulfill(route, ready);
      return;
    }
    if (url.pathname === "/api/v1/references/analyze") {
      const asset = body.reference_asset as Json;
      session = {
        ...session,
        state: "reference_ready",
        reference_asset: asset,
        active_reference_analysis_id: "ra_e2e",
      };
      await fulfill(
        route,
        {
          schema_version: "1.0",
          analysis_id: "ra_e2e",
          reference_id: asset.reference_id,
          person_count: 1,
          target_layout: layout,
          composition_notes: ["人物位于门廊中央。"],
          safety_status: "safe",
          safety_warnings: [],
          confidence: 0.94,
        },
        202,
        asset.source_type === "preset" ? "fixture" : "live",
      );
      return;
    }
    if (url.pathname === "/api/v1/references/adapt") {
      adaptRequestCount += 1;
      if ((options.adaptDelayMs ?? 0) > 0) {
        await new Promise((resolveDelay) => setTimeout(resolveDelay, options.adaptDelayMs));
      }
      if (remainingAdaptFailures > 0) {
        remainingAdaptFailures -= 1;
        await fulfillError(route, "PROVIDER_REJECTED", 422);
        return;
      }
      session = {
        ...session,
        state: "reference_ready",
        scene_asset_id: body.scene_asset_id,
        active_reference_analysis_id: "ra_e2e_adapted",
      };
      await fulfill(
        route,
        {
          schema_version: "1.0",
          analysis_id: "ra_e2e_adapted",
          reference_id: (session.reference_asset as Json).reference_id,
          person_count: 1,
          target_layout: layout,
          composition_notes: ["已按当前现场重新规划。"],
          safety_status: "safe",
          safety_warnings: [],
          confidence: 0.9,
        },
        202,
        "live",
      );
      return;
    }
    if (url.pathname === "/api/v1/agent/runs") {
      if ((options.planDelayMs ?? 0) > 0) {
        await new Promise((resolveDelay) => setTimeout(resolveDelay, options.planDelayMs));
      }
      const sceneMode = body.intent === "scene_adaptation";
      session = {
        ...session,
        state: "shot_plan_ready",
        shot_plan: plan,
        selected_skills: [{ name: "shooting_plan", version: sceneMode ? "1.1.0" : "1.0.0" }],
      };
      const mode = body.intent === "original_replication" && (session.reference_asset as Json).source_type === "preset" ? "fixture" : "live";
      await fulfill(route, { run_id: "run_e2e", selected_skills: session.selected_skills }, 202, mode);
      return;
    }
    if (url.pathname === "/api/v1/sessions/ss_e2e") {
      await fulfill(route, session);
      return;
    }
    if (url.pathname === "/api/v1/captures") {
      const capture = {
        schema_version: "1.0",
        capture_id: `cap_e2e_${body.round_index}`,
        session_id: "ss_e2e",
        round_index: body.round_index,
        media_asset_id: body.media_asset_id,
        status: "ready",
        selected_frame_id: null,
        created_at: now,
      };
      session = {
        ...session,
        state: "capturing",
        capture_rounds: [...(session.capture_rounds as Json[]), capture],
      };
      await fulfill(route, capture, 201);
      return;
    }
    if (url.pathname === "/api/v1/evaluations") {
      const first = String(body.capture_id).endsWith("_1");
      const fixture = (session.reference_asset as Json).source_type === "preset" && session.mode === "original_replication";
      const evaluation = first
        ? {
            schema_version: "1.0",
            evaluation_id: "eval_e2e_1",
            capture_id: body.capture_id,
            issue_code: "person_too_small",
            top_issue: "人物在门框中的占比偏小。",
            next_instruction: "向前一步，其他动作保持不变",
            needs_retake: true,
            goal_satisfied: false,
            publish_readiness: 0.58,
            confidence: 0.86,
            execution_mode: fixture ? "fixture" : "live",
          }
        : {
            schema_version: "1.0",
            evaluation_id: "eval_e2e_2",
            capture_id: body.capture_id,
            needs_retake: false,
            goal_satisfied: true,
            publish_readiness: 0.9,
            confidence: 0.88,
            execution_mode: fixture ? "fixture" : "live",
          };
      session = {
        ...session,
        state: first ? "coaching" : "completed",
        evaluation,
        evaluations: [...(session.evaluations as Json[]), evaluation],
      };
      await fulfill(route, evaluation, 202, fixture ? "fixture" : "live");
      return;
    }
    if (url.pathname.endsWith("/access")) {
      const id = url.pathname.split("/").at(-2)!;
      await fulfill(route, {
        schema_version: "1.0",
        asset: media.get(id),
        download_url: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='2' height='2'/%3E",
        access_expires_at: new Date(Date.now() + 300_000).toISOString(),
      });
      return;
    }
    if (url.pathname === "/api/v1/events/batch") {
      await fulfill(route, { schema_version: "1.0", accepted_count: 1, duplicate_count: 0 }, 202);
      return;
    }
    await route.abort("failed");
  });
  return {
    mediaUploadCount: () => counter,
    adaptRequestCount: () => adaptRequestCount,
    allowAdapt: () => {
      remainingAdaptFailures = 0;
    },
  };
}

async function selectPreset(page: Page) {
  await page.getByRole("button", { name: "开始创作" }).click();
  await page.getByRole("button", { name: /门廊光影/ }).click();
  await page.getByRole("button", { name: "就是这个瞬间" }).click();
}

async function selectCustom(page: Page) {
  await page.getByRole("button", { name: "我的参考" }).click();
  await page.getByRole("button", { name: "开始创作" }).click();
  await page.getByLabel("从相册选择").setInputFiles(testImagePath);
  await expect(page.getByText("已选好")).toBeVisible();
  await page.getByRole("button", { name: "就是这个瞬间" }).click();
  await page.getByRole("checkbox").check();
}

async function uploadCaptureAndEvaluate(page: Page, round: 1 | 2) {
  await page.getByLabel("从相册选择").setInputFiles(testImagePath);
  await expect(page.getByText("已选好")).toBeVisible();
  await page.getByRole("button", { name: "看看这一拍" }).click();
}

test("public preset completes the honest two-round flow with refresh recovery", async ({ page }) => {
  await installApiRoutes(page);
  await page.goto("/");
  await selectPreset(page);
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await expect(page.getByRole("heading", { name: "你的灵感，已经读懂" })).toBeVisible();
  await page.reload();
  await expect(page.getByRole("heading", { name: "你的灵感，已经读懂" })).toBeVisible();
  await page.getByRole("button", { name: "生成我的 ShotPlan" }).click();
  await expect(page.getByRole("heading", { name: "你的专属 ShotPlan" })).toBeVisible();
  await page.reload();
  await expect(page.getByRole("heading", { name: "你的专属 ShotPlan" })).toBeVisible();
  await page.getByRole("button", { name: "直接拍照或上传" }).click();
  await page.getByRole("button", { name: "查看第一次建议" }).click();
  await expect(page.getByRole("heading", { name: "人物比例偏小" })).toBeVisible();
  await page.reload();
  await expect(page.getByRole("heading", { name: "人物比例偏小" })).toBeVisible();
  await page.getByRole("button", { name: "带着这条建议再拍一次" }).click();
  await page.getByRole("button", { name: "查看第二次变化" }).click();
  await page.getByRole("button", { name: "查看我的作品" }).click();
  await expect(page.getByRole("heading", { name: "一次调整，画面已经不同" })).toBeVisible();
  await page.reload();
  await expect(page.getByRole("heading", { name: "一次调整，画面已经不同" })).toBeVisible();
  await expect(page.getByText(/不生成虚构的前后对比照片/)).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("ShotPlan exposes browser live coaching while preserving upload fallback", async ({ page }) => {
  await installApiRoutes(page);
  await page.goto("/");
  await selectPreset(page);
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await page.getByRole("button", { name: "生成我的 ShotPlan" }).click();
  await page.getByRole("button", { name: "浏览器免安装陪拍" }).click();
  await expect(page.getByRole("heading", { name: "浏览器现场陪拍" })).toBeVisible();
  await expect(page.getByText("只有你最终确认的一张 JPEG 会被上传用于评价。")).toBeVisible();
  await page.getByRole("button", { name: "直接拍照或上传" }).click();
  await expect(page.getByRole("heading", { name: "第一次，先完整拍下来" })).toBeVisible();
});

test("browser live coaching restores a selected local JPEG after refresh", async ({ page }) => {
  await installApiRoutes(page);
  await page.goto("/");
  await selectPreset(page);
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await page.getByRole("button", { name: "生成我的 ShotPlan" }).click();
  await page.evaluate(async () => {
    const database = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("soloshot-live-coach", 1);
      request.onupgradeneeded = () => {
        if (!request.result.objectStoreNames.contains("capture-drafts")) {
          request.result.createObjectStore("capture-drafts");
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () =>
        reject(new Error(request.error?.message ?? "Could not open live-coach test database"));
    });
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction("capture-drafts", "readwrite");
      transaction.objectStore("capture-drafts").put(
        {
          sessionId: "ss_e2e",
          round: 1,
          blobBytes: new Uint8Array([255, 216, 255, 217]).buffer,
          blobType: "image/jpeg",
          width: 720,
          height: 1280,
          candidateId: "frame_h5_restored",
          selectionSource: "local_recommended",
          localScore: 0.88,
          reasons: ["站位更接近 ShotPlan"],
          createdAt: Date.now(),
          uploadCreateKey: "h5-live-upload-restored",
          uploadCompleteKey: "h5-live-complete-restored",
          captureKey: "h5-live-capture-restored",
          evaluationKey: "h5-live-evaluation-restored",
          networkStep: "consent",
          mediaAssetId: null,
          captureId: null,
        },
        "ss_e2e:1",
      );
      transaction.oncomplete = () => resolve();
      transaction.onerror = () =>
        reject(new Error(transaction.error?.message ?? "Could not seed live-coach test draft"));
    });
    database.close();
    sessionStorage.setItem("soloshot:live-coach:ss_e2e", "1");
  });
  await page.goto("/session/ss_e2e/live/1");
  await expect(page.getByRole("heading", { name: "选出第一次成片" })).toBeVisible();
  await expect(page.getByText("站位更接近 ShotPlan")).toBeVisible();
  await page.reload();
  await expect(page.getByRole("button", { name: /确认这一张并开始评价/ })).toBeVisible();
});

test("versioned MediaPipe model and runtime assets are served locally", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Static asset delivery is browser-independent.");
  const manifest = await page.request.get("/models/mediapipe/model-manifest.json");
  expect(manifest.ok()).toBe(true);
  expect((await manifest.json()).runtime_version).toBe("0.10.35");
  const model = await page.request.get("/models/mediapipe/pose-landmarker-lite-v1.task");
  expect(model.ok()).toBe(true);
  expect((await model.body()).byteLength).toBeGreaterThan(5_000_000);
  const segmenter = await page.request.get("/models/mediapipe/selfie-segmenter-float16-v1.tflite");
  expect(segmenter.ok()).toBe(true);
  expect((await segmenter.body()).byteLength).toBeGreaterThan(200_000);
  const wasm = await page.request.get("/mediapipe/0.10.35/wasm/vision_wasm_internal.wasm");
  expect(wasm.ok()).toBe(true);
  expect(wasm.headers()["content-type"]).toContain("application/wasm");
});

test("browser coaching prewarms the self-hosted model without a runtime CDN", async ({ page }, testInfo) => {
  test.skip(
    !["mobile-chromium", "mobile-webkit"].includes(testInfo.project.name),
    "One mobile compile smoke per browser engine is sufficient in CI.",
  );
  await installApiRoutes(page);
  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));
  await page.goto("/");
  await selectPreset(page);
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await page.getByRole("button", { name: "生成我的 ShotPlan" }).click();
  await page.getByRole("button", { name: "浏览器免安装陪拍" }).click();
  await page.getByRole("button", { name: "开启相机并开始陪拍" }).click();
  await page.waitForURL(/\/session\/ss_e2e\/live\/1/, { timeout: 30_000 });
  const cachedReference = await page.evaluate(() => {
    const raw = sessionStorage.getItem("soloshot:reference-silhouette:1:ss_e2e");
    return raw === null ? null : JSON.parse(raw) as { status?: string; contour?: { loops?: unknown[] } };
  });
  expect(cachedReference?.status).toBe("ready");
  expect(cachedReference?.contour?.loops?.length).toBeGreaterThan(0);
  const outer = cachedReference?.contour?.loops?.[0] as Array<{ x: number; y: number }> | undefined;
  const outerArea = outer?.reduce((sum, point, index) => {
    const next = outer[(index + 1) % outer.length] ?? point;
    return sum + point.x * next.y - next.x * point.y;
  }, 0) ?? 0;
  expect(Math.abs(outerArea / 2)).toBeGreaterThan(0.1);
  expect(Math.abs(outerArea / 2)).toBeLessThan(0.9);
  expect(requested.some((url) => url.includes("/models/mediapipe/pose-landmarker-lite-v1.task"))).toBe(true);
  expect(requested.some((url) => url.includes("/models/mediapipe/selfie-segmenter-float16-v1.tflite"))).toBe(true);
  expect(requested.some((url) => url.includes("/mediapipe/0.10.35/wasm/"))).toBe(true);
  expect(
    requested.filter((url) => /googleapis|gstatic|unpkg|jsdelivr|cdn\.jsdelivr/.test(url)),
  ).toEqual([]);
});

test("custom original replication completes a real-media Live mock flow", async ({ page }) => {
  await installApiRoutes(page);
  await page.goto("/");
  await selectCustom(page);
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await page.getByRole("button", { name: "生成我的 ShotPlan" }).click();
  await page.getByRole("button", { name: "直接拍照或上传" }).click();
  await uploadCaptureAndEvaluate(page, 1);
  await page.getByRole("button", { name: "带着这条建议再拍一次" }).click();
  await uploadCaptureAndEvaluate(page, 2);
  await page.getByRole("button", { name: "查看我的作品" }).click();
  await expect(page.getByText("这里展示的照片都来自本次旅拍。")).toBeVisible();
  await expect(page.locator(".live-comparison .round-media")).toHaveCount(3);
  await expect(page.locator(".live-comparison").getByText("参考", { exact: true })).toBeVisible();
  await expect(page.locator(".live-comparison").getByText("第一拍", { exact: true })).toBeVisible();
  await expect(page.locator(".live-comparison").getByText("第二拍", { exact: true })).toBeVisible();
  const comparisonLayout = await page.locator(".live-comparison").evaluate((element) => ({
    display: getComputedStyle(element).display,
    scrollable: element.scrollWidth > element.clientWidth,
  }));
  if ((page.viewportSize()?.width ?? 0) >= 900) {
    expect(comparisonLayout.display).toBe("grid");
  } else {
    expect(comparisonLayout.scrollable).toBe(true);
  }
});

for (const source of ["preset", "custom"] as const) {
  test(`${source} reference reaches a Live scene-adapted ShotPlan`, async ({ page }) => {
    await installApiRoutes(page);
    await page.goto("/");
    await page.getByRole("button", { name: /灵感迁移/ }).click();
    if (source === "preset") {
      await selectPreset(page);
      await page.getByRole("checkbox").check();
    } else {
      await selectCustom(page);
    }
    await page.getByRole("button", { name: "交给 SoloShot" }).click();
    await page.getByRole("button", { name: "看看我眼前的现场" }).click();
    await page.getByLabel("从相册选择").setInputFiles(testImagePath);
    await expect(page.getByText("已选好")).toBeVisible();
    await expect(page.getByRole("heading", { name: "你的专属 ShotPlan" })).toBeVisible();
    await expect(page.getByLabel("现场人物目标布局")).toBeVisible();
    await expect(page.getByText("实时分析", { exact: true }).first()).toBeVisible();
  });
}

test("scene retry reuses the uploaded image after a model rejection", async ({ page }) => {
  const diagnostics = await installApiRoutes(page, { adaptFailures: Number.MAX_SAFE_INTEGER });
  await page.goto("/");
  await page.getByRole("button", { name: /灵感迁移/ }).click();
  await selectPreset(page);
  await page.getByRole("checkbox").check();
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await page.getByRole("button", { name: "看看我眼前的现场" }).click();
  await page.getByLabel("从相册选择").setInputFiles(testImagePath);
  await expect(page.getByText("这张画面暂时没有分析完成", { exact: true })).toBeVisible();
  expect(diagnostics.adaptRequestCount()).toBe(1);
  diagnostics.allowAdapt();
  await page.getByRole("button", { name: "再试一次" }).click();
  await expect(page.getByRole("heading", { name: "你的专属 ShotPlan" })).toBeVisible();
  expect(diagnostics.mediaUploadCount()).toBe(1);
});

test("scene selection exposes real upload, recognition and planning stages", async ({ page }) => {
  await installApiRoutes(page, { uploadDelayMs: 250, adaptDelayMs: 250, planDelayMs: 250 });
  await page.goto("/");
  await page.getByRole("button", { name: /灵感迁移/ }).click();
  await selectPreset(page);
  await page.getByRole("checkbox").check();
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await page.getByRole("button", { name: "看看我眼前的现场" }).click();
  await page.getByLabel("从相册选择").setInputFiles(testImagePath);

  await expect(page.getByText("正在上传现场图")).toBeVisible();
  await expect(page.getByText("正在识别人物与构图")).toBeVisible();
  await expect(page.getByText("正在生成拍摄步骤")).toBeVisible();
  await expect(page.getByRole("heading", { name: "你的专属 ShotPlan" })).toBeVisible();
});

test("H5 handoff survives refresh and follows iOS claim through completion", async ({ page }) => {
  await installApiRoutes(page);
  await page.goto("/");
  await selectPreset(page);
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await page.getByRole("button", { name: "生成我的 ShotPlan" }).click();
  await page.getByRole("button", { name: "让 iPhone 现场陪我拍" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(page.getByLabel("任务码 294816")).toHaveCount(0);
  await page.waitForTimeout(300);
  const sheetMetrics = await page.getByRole("dialog").evaluate((sheet) => {
    const sheetBox = sheet.getBoundingClientRect();
    const actionsBox = sheet.querySelector(".ios-experience-actions")?.getBoundingClientRect();
    return {
      top: sheetBox.top,
      bottom: sheetBox.bottom,
      height: sheetBox.height,
      actionsBottom: actionsBox?.bottom ?? 0,
      viewportHeight: window.innerHeight,
      fitsWidth: document.documentElement.scrollWidth <= window.innerWidth,
    };
  });
  expect(sheetMetrics.top).toBeGreaterThanOrEqual(0);
  expect(sheetMetrics.bottom).toBeLessThanOrEqual(sheetMetrics.viewportHeight + 1);
  expect(sheetMetrics.height).toBeLessThanOrEqual(sheetMetrics.viewportHeight * 0.88 + 1);
  expect(Math.abs(sheetMetrics.actionsBottom - sheetMetrics.bottom)).toBeLessThanOrEqual(1);
  expect(sheetMetrics.fitsWidth).toBe(true);
  await page.getByRole("button", { name: "生成现场体验码" }).click();

  await expect(page.getByLabel("任务码 294816")).toBeVisible();
  await expect(page.getByAltText("iPhone 接力二维码")).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("soloshot:handoff:v1:ss_e2e"))).toBeNull();
  await page.reload();
  await expect(page.getByLabel("任务码 294816")).toBeVisible();

  await page.evaluate(async () => {
    await fetch("http://localhost:8000/api/v1/handoffs/294816/claim", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Idempotency-Key": "ios-e2e-claim" },
      body: JSON.stringify({ schema_version: "1.0", client_instance_id: "ios-e2e" }),
    });
  });
  await expect(page.getByText("正在同步到 iPhone")).toBeVisible({ timeout: 5_000 });

  await page.evaluate(async () => {
    await fetch("http://localhost:8000/api/v1/handoffs/294816/complete", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Idempotency-Key": "ios-e2e-complete",
        "X-Handoff-Claim-Token": "claim-token-e2e-claim-token-e2e",
      },
      body: JSON.stringify({ schema_version: "1.0", client_instance_id: "ios-e2e" }),
    });
  });
  await expect(page.getByText("iPhone 已就绪").first()).toBeVisible({ timeout: 5_000 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("W5 cross-device handoff follows two iOS rounds into the honest result", async ({ page }) => {
  await installApiRoutes(page);
  await page.goto("/");
  await selectPreset(page);
  await page.getByRole("button", { name: "交给 SoloShot" }).click();
  await page.getByRole("button", { name: "生成我的 ShotPlan" }).click();
  await page.getByRole("button", { name: "让 iPhone 现场陪我拍" }).click();
  await page.getByRole("button", { name: "生成现场体验码" }).click();

  await page.evaluate(async () => {
    const json = (method: string, body: unknown, key: string) => ({
      method,
      headers: { "Content-Type": "application/json", "Idempotency-Key": key },
      body: JSON.stringify(body),
    });
    await fetch("http://localhost:8000/api/v1/handoffs/294816/claim", json("POST", {
      schema_version: "1.0", client_instance_id: "ios-w5-e2e",
    }, "claim-w5"));
    await fetch("http://localhost:8000/api/v1/handoffs/294816/complete", {
      ...json("POST", { schema_version: "1.0", client_instance_id: "ios-w5-e2e" }, "complete-w5"),
      headers: {
        "Content-Type": "application/json",
        "Idempotency-Key": "complete-w5",
        "X-Handoff-Claim-Token": "claim-token-e2e-claim-token-e2e",
      },
    });
  });
  await expect(page.getByText("iPhone 已就绪").first()).toBeVisible({ timeout: 5_000 });

  const submitRound = async (round: 1 | 2) => {
    await page.evaluate(async (roundIndex) => {
      const request = (body: unknown, key: string) => ({
        method: "POST",
        headers: { "Content-Type": "application/json", "Idempotency-Key": key },
        body: JSON.stringify(body),
      });
      const uploadResponse = await fetch("http://localhost:8000/api/v1/media/uploads", request({
        schema_version: "1.0",
        session_id: "ss_e2e",
        purpose: "capture",
        content_type: "image/jpeg",
        byte_size: 6,
        sha256: "a".repeat(64),
      }, `ios-upload-${roundIndex}`));
      const upload = await uploadResponse.json();
      await fetch(upload.data.upload_url, {
        method: "PUT",
        headers: upload.data.upload_headers,
        body: new Uint8Array([255, 216, 1, 2, 255, 217]),
      });
      await fetch(
        `http://localhost:8000/api/v1/media/uploads/${upload.data.asset.media_asset_id}/complete`,
        request({ schema_version: "1.0", session_id: "ss_e2e" }, `ios-complete-${roundIndex}`),
      );
      const captureResponse = await fetch("http://localhost:8000/api/v1/captures", request({
        schema_version: "1.0",
        session_id: "ss_e2e",
        round_index: roundIndex,
        media_asset_id: upload.data.asset.media_asset_id,
        capture_method: "photo",
        frame_selection: {
          frame_id: `frame_ios_${roundIndex}`,
          timestamp_ms: 0,
          selection_source: "local_recommended",
        },
      }, `ios-capture-${roundIndex}`));
      const capture = await captureResponse.json();
      await fetch("http://localhost:8000/api/v1/evaluations", request({
        schema_version: "1.0",
        session_id: "ss_e2e",
        capture_id: capture.data.capture_id,
      }, `ios-evaluation-${roundIndex}`));
    }, round);
  };

  await submitRound(1);
  await expect(page.getByText("第一次建议已生成，iPhone 正在准备调整后的拍摄。")).toBeVisible({ timeout: 5_000 });
  await page.reload();
  await expect(page.getByText("第一次建议已生成，iPhone 正在准备调整后的拍摄。")).toBeVisible({ timeout: 5_000 });
  await submitRound(2);
  await expect(page.getByRole("button", { name: "查看我的作品" })).toBeVisible({ timeout: 5_000 });
  await page.getByRole("button", { name: "查看我的作品" }).click();
  await expect(page.getByText(/从第一拍到第二拍，SoloShot 只让你改最关键的一步/)).toBeVisible();
  await expect(page.getByText(/作品就绪度为演示参考，不代表 AI 对照片的判断/)).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
