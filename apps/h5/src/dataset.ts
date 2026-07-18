import type { components } from "./generated/api";
import rawManifest from "../../../packages/evals/test-image-v1/manifest.json";

type ReferenceAsset = components["schemas"]["ReferenceAsset"];
type TargetLayout = components["schemas"]["TargetLayout"];

export type PublicAssets = {
  thumbnail: string;
  detail: string;
};

export type TestImageCase = {
  caseId: string;
  referenceId: string;
  title: string;
  subtitle: string;
  tags: string[];
  difficulty: "baseline" | "coverage" | "hard";
  publicAssets: PublicAssets;
  referenceAsset: ReferenceAsset;
  expectedReference: {
    personCount: number;
    targetLayout: TargetLayout;
    compositionNotes: string[];
    confidence: number;
  };
};

type UnknownRecord = Record<string, unknown>;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function parseReferenceAsset(value: unknown): ReferenceAsset {
  if (
    !isRecord(value) ||
    value.schema_version !== "1.0" ||
    typeof value.reference_id !== "string" ||
    value.media_type !== "image" ||
    value.source_type !== "preset" ||
    !isNumber(value.width) ||
    !isNumber(value.height) ||
    !isRecord(value.selected_box) ||
    !isNumber(value.selected_box.x) ||
    !isNumber(value.selected_box.y) ||
    !isNumber(value.selected_box.width) ||
    !isNumber(value.selected_box.height) ||
    !isRecord(value.attribution) ||
    typeof value.attribution.source_label !== "string"
  ) {
    throw new Error("Test Image v1 contains an invalid ReferenceAsset");
  }
  return value as ReferenceAsset;
}

function parseTargetLayout(value: unknown): TargetLayout {
  if (
    !isRecord(value) ||
    !isNumber(value.center_x) ||
    !isNumber(value.center_y) ||
    !isNumber(value.width) ||
    !isNumber(value.height) ||
    !isRecord(value.head_point) ||
    !isNumber(value.head_point.x) ||
    !isNumber(value.head_point.y) ||
    !isNumber(value.foot_line_y) ||
    typeof value.body_direction !== "string" ||
    typeof value.pose_template !== "string"
  ) {
    throw new Error("Test Image v1 contains an invalid target layout");
  }
  return value as TargetLayout;
}

function parseCase(value: unknown): TestImageCase | null {
  if (!isRecord(value) || value.public_preset !== true) {
    return null;
  }
  const publicAssets = value.public_assets;
  const expected = value.expected_reference;
  if (
    typeof value.case_id !== "string" ||
    typeof value.reference_id !== "string" ||
    typeof value.title !== "string" ||
    typeof value.subtitle !== "string" ||
    !isStringArray(value.tags) ||
    !["baseline", "coverage", "hard"].includes(String(value.difficulty)) ||
    !isRecord(publicAssets) ||
    typeof publicAssets.thumbnail !== "string" ||
    typeof publicAssets.detail !== "string" ||
    !isRecord(expected) ||
    !isNumber(expected.person_count) ||
    !isStringArray(expected.composition_notes) ||
    !isNumber(expected.confidence)
  ) {
    throw new Error("Test Image v1 contains an invalid public preset");
  }
  return {
    caseId: value.case_id,
    referenceId: value.reference_id,
    title: value.title,
    subtitle: value.subtitle,
    tags: value.tags,
    difficulty: value.difficulty as TestImageCase["difficulty"],
    publicAssets: {
      thumbnail: publicAssets.thumbnail,
      detail: publicAssets.detail,
    },
    referenceAsset: parseReferenceAsset(value.reference_asset),
    expectedReference: {
      personCount: expected.person_count,
      targetLayout: parseTargetLayout(expected.target_layout),
      compositionNotes: expected.composition_notes,
      confidence: expected.confidence,
    },
  };
}

function loadDataset(value: unknown): { version: string; cases: TestImageCase[] } {
  if (!isRecord(value) || value.dataset_version !== "test-image-v1" || !Array.isArray(value.cases)) {
    throw new Error("Test Image v1 manifest is unavailable");
  }
  const cases = value.cases.map(parseCase).filter((item): item is TestImageCase => item !== null);
  if (cases.length !== 4) {
    throw new Error("Test Image v1 must expose exactly four public presets");
  }
  return { version: value.dataset_version, cases };
}

export const testImageDataset = loadDataset(rawManifest as unknown);

export function findTestImageCase(caseId: string | null): TestImageCase | null {
  return testImageDataset.cases.find((item) => item.caseId === caseId) ?? null;
}

export const tagLabels: Readonly<Record<string, string>> = {
  full_body: "全身",
  three_quarter: "半身构图",
  closeup: "近景",
  standing: "站姿",
  seated: "坐姿",
  profile: "侧身",
  architecture: "建筑框景",
  travel: "旅行场景",
  indoor: "室内",
  outdoor: "室外",
};
