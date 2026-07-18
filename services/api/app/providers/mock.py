from __future__ import annotations

import json
import logging
from copy import deepcopy
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from typing import cast

from app.domain.errors import DomainError
from app.domain.ids import new_id
from app.domain.models import JsonObject
from app.providers.base import ProviderResult

logger = logging.getLogger("soloshot.providers.fixture")
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_MANIFEST_PATH = REPOSITORY_ROOT / "packages/evals/test-image-v1/manifest.json"


class DeterministicMockProvider:
    name = "mock"
    execution_mode = "mock"
    model_name = "test-image-fixture-v1"

    def has_reference(self, reference_id: str) -> bool:
        return reference_id in self._cases_by_reference

    def __init__(self, manifest_path: Path | None = None) -> None:
        self.manifest_path = manifest_path or DEFAULT_MANIFEST_PATH
        self.dataset_version = "legacy-fixture"
        self._cases_by_reference: dict[str, JsonObject] = {}
        self._cases_by_id: dict[str, JsonObject] = {}
        if self.manifest_path.exists():
            payload = json.loads(self.manifest_path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict) or not isinstance(payload.get("cases"), list):
                raise RuntimeError("Test Image fixture manifest is invalid")
            self.dataset_version = str(payload.get("dataset_version", "test-image-v1"))
            for raw_case in payload["cases"]:
                if not isinstance(raw_case, dict):
                    raise RuntimeError("Test Image fixture case must be an object")
                case = cast(JsonObject, raw_case)
                reference_id = case.get("reference_id")
                case_id = case.get("case_id")
                if not isinstance(reference_id, str) or not isinstance(case_id, str):
                    raise RuntimeError("Test Image fixture case identifiers are required")
                self._cases_by_reference[reference_id] = case
                self._cases_by_id[case_id] = case

    async def invoke(
        self,
        skill_name: str,
        input_data: JsonObject,
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        handlers = {
            "reference_understanding": self._reference,
            "shooting_plan": self._shot_plan,
            "result_evaluation": self._evaluation,
            "content_composer": self._content,
        }
        handler = handlers.get(skill_name)
        if handler is None:
            raise DomainError(
                "SKILL_NOT_FOUND", f"Skill {skill_name} is unavailable", status_code=404
            )
        result = handler(input_data)
        case_id = self._case_id_for_input(skill_name, input_data)
        if case_id is not None:
            logger.info(
                "fixture_invoked skill=%s dataset_version=%s case_id=%s fixture=true",
                skill_name,
                self.dataset_version,
                case_id,
            )
        return result

    def _case_id_for_input(self, skill_name: str, input_data: JsonObject) -> str | None:
        if skill_name == "reference_understanding":
            asset = input_data.get("reference_asset")
            if isinstance(asset, dict):
                reference_id = asset.get("reference_id")
                if isinstance(reference_id, str):
                    case = self._cases_by_reference.get(reference_id)
                    if case is not None:
                        return cast(str, case["case_id"])
        if skill_name == "shooting_plan":
            analysis = input_data.get("reference_analysis")
            if isinstance(analysis, dict):
                reference_id = analysis.get("reference_id")
                if isinstance(reference_id, str):
                    case = self._cases_by_reference.get(reference_id)
                    if case is not None:
                        return cast(str, case["case_id"])
        if skill_name == "result_evaluation":
            capture = input_data.get("capture")
            if isinstance(capture, dict):
                media_asset_id = capture.get("media_asset_id")
                round_index = capture.get("round_index")
                if isinstance(media_asset_id, str) and isinstance(round_index, int):
                    return self._case_id_for_media(media_asset_id, round_index)
        return None

    def _fixture_warning(self, case_id: str) -> str:
        return (
            "MOCK_FIXTURE "
            f"dataset_version={self.dataset_version} case_id={case_id} fixture=true"
        )

    def _case_id_for_media(self, media_asset_id: str, round_index: int) -> str | None:
        for case_id in self._cases_by_id:
            if media_asset_id == f"media_fixture_{case_id}_round_{round_index}":
                return case_id
        return None

    def _reference(self, input_data: JsonObject) -> ProviderResult:
        asset = input_data["reference_asset"]
        if not isinstance(asset, dict):
            raise DomainError("VALIDATION_FAILED", "reference_asset must be an object")
        selected = asset["selected_box"]
        if not isinstance(selected, dict):
            raise DomainError("VALIDATION_FAILED", "selected_box must be an object")
        reference_id = asset.get("reference_id")
        if isinstance(reference_id, str):
            fixture_case = self._cases_by_reference.get(reference_id)
            if fixture_case is not None:
                expected = fixture_case.get("expected_reference")
                if not isinstance(expected, dict):
                    raise DomainError("INVALID_JSON", "Fixture reference output is invalid")
                case_id = cast(str, fixture_case["case_id"])
                fixture_output = deepcopy(cast(JsonObject, expected))
                fixture_output.update(
                    {
                        "schema_version": "1.0",
                        "analysis_id": new_id("ra"),
                        "reference_id": reference_id,
                    }
                )
                confidence = float(fixture_output["confidence"])
                return ProviderResult(
                    output=fixture_output,
                    confidence=confidence,
                    model=self.model_name,
                    warnings=[self._fixture_warning(case_id)],
                )
        x = float(selected["x"])
        y = float(selected["y"])
        width = float(selected["width"])
        height = float(selected["height"])
        output: JsonObject = {
            "schema_version": "1.0",
            "analysis_id": new_id("ra"),
            "reference_id": asset["reference_id"],
            "person_count": 1,
            "target_layout": {
                "center_x": x + width / 2,
                "center_y": y + height / 2,
                "width": width,
                "height": height,
                "head_point": {"x": x + width / 2, "y": y},
                "foot_line_y": min(1.0, y + height),
                "body_direction": "slightly_left",
                "pose_template": "walking_turn",
            },
            "composition_notes": [
                "Mock：人物位于右侧三分区域，保留环境纵深。",
                "Mock：仅使用用户圈选框生成确定性布局。",
            ],
            "confidence": 0.86,
        }
        return ProviderResult(
            output=output,
            confidence=0.86,
            model=self.model_name,
            warnings=["MOCK_OUTPUT_NOT_LIVE_MODEL"],
        )

    def _shot_plan(self, input_data: JsonObject) -> ProviderResult:
        analysis = input_data["reference_analysis"]
        if not isinstance(analysis, dict):
            raise DomainError("VALIDATION_FAILED", "reference_analysis must be an object")
        layout = analysis["target_layout"]
        reference_id = analysis.get("reference_id")
        if isinstance(reference_id, str):
            fixture_case = self._cases_by_reference.get(reference_id)
            if fixture_case is not None:
                fixture = fixture_case.get("shot_plan_fixture")
                if not isinstance(fixture, dict):
                    raise DomainError("INVALID_JSON", "Fixture ShotPlan output is invalid")
                case_id = cast(str, fixture_case["case_id"])
                fixture_output = deepcopy(cast(JsonObject, fixture))
                fixture_output.update(
                    {
                        "schema_version": "1.0",
                        "plan_id": new_id("sp"),
                        "target_layout": layout,
                        "h5_execution": {
                            "supported": True,
                            "instruction": "使用静态构图预览，并通过文件上传提交结果。",
                            "requires_realtime_alignment": False,
                        },
                        "ios_execution": {
                            "supported": True,
                            "instruction": "使用本地 Vision 与屏幕空间轮廓进行实时对齐。",
                            "requires_realtime_alignment": True,
                        },
                    }
                )
                confidence = float(fixture_output["confidence"])
                return ProviderResult(
                    output=fixture_output,
                    confidence=confidence,
                    model=self.model_name,
                    warnings=[self._fixture_warning(case_id)],
                )
        output: JsonObject = {
            "schema_version": "1.0",
            "plan_id": new_id("sp"),
            "camera_height": "waist",
            "camera_angle": "slight_up",
            "lens": "1x",
            "capture_mode": "short_video",
            "phone_setup_instruction": "将手机竖直固定在稳定支撑物上，确认不会滑落。",
            "target_layout": layout,
            "action_script": [
                {
                    "sequence": 1,
                    "instruction": "从画面左侧缓慢走向目标位置。",
                    "duration_seconds": 3,
                },
                {"sequence": 2, "instruction": "到位后轻轻向风景方向回头。", "duration_seconds": 2},
            ],
            "safety_notes": [
                "只在平整、允许停留且远离车辆的区域拍摄。",
                "手机必须放在稳定支撑物上。",
            ],
            "h5_execution": {
                "supported": True,
                "instruction": "使用静态轮廓预览，并通过文件上传提交结果。",
                "requires_realtime_alignment": False,
            },
            "ios_execution": {
                "supported": True,
                "instruction": "使用本地 Vision 与屏幕空间轮廓进行实时对齐。",
                "requires_realtime_alignment": True,
            },
            "confidence": 0.84,
        }
        return ProviderResult(
            output=output,
            confidence=0.84,
            model=self.model_name,
            warnings=["MOCK_OUTPUT_NOT_LIVE_MODEL"],
        )

    def _evaluation(self, input_data: JsonObject) -> ProviderResult:
        capture = input_data["capture"]
        if not isinstance(capture, dict):
            raise DomainError("VALIDATION_FAILED", "capture must be an object")
        media_asset_id = capture.get("media_asset_id")
        round_index = capture.get("round_index")
        if isinstance(media_asset_id, str) and isinstance(round_index, int):
            case_id = self._case_id_for_media(media_asset_id, round_index)
            if case_id is not None:
                fixture_case = self._cases_by_id[case_id]
                raw_evaluations = fixture_case.get("result_evaluations")
                if not isinstance(raw_evaluations, list):
                    raise DomainError("INVALID_JSON", "Fixture evaluations are invalid")
                raw_evaluation = next(
                    (
                        item
                        for item in raw_evaluations
                        if isinstance(item, dict) and item.get("round_index") == round_index
                    ),
                    None,
                )
                if raw_evaluation is None:
                    raise DomainError(
                        "NOT_FOUND",
                        f"Fixture evaluation is missing for {case_id} round {round_index}",
                        status_code=404,
                    )
                fixture_output = deepcopy(cast(JsonObject, raw_evaluation))
                fixture_output.pop("round_index", None)
                fixture_output.pop("fixture_status", None)
                fixture_output.update(
                    {
                        "schema_version": "1.0",
                        "evaluation_id": new_id("eval"),
                        "capture_id": capture["capture_id"],
                    }
                )
                confidence = float(fixture_output["confidence"])
                return ProviderResult(
                    output=fixture_output,
                    confidence=confidence,
                    model=self.model_name,
                    warnings=[self._fixture_warning(case_id)],
                )
        output: JsonObject = {
            "schema_version": "1.0",
            "evaluation_id": new_id("eval"),
            "capture_id": capture["capture_id"],
            "issue_code": "person_too_large",
            "top_issue": "人物距离镜头过近，遮挡了背景主体",
            "next_instruction": "后退两步，其他动作保持不变",
            "needs_retake": True,
            "goal_satisfied": False,
            "publish_readiness": 0.62,
            "confidence": 0.81,
        }
        return ProviderResult(
            output=output,
            confidence=0.81,
            model=self.model_name,
            warnings=["MOCK_OUTPUT_NOT_LIVE_MODEL"],
        )

    def _content(self, input_data: JsonObject) -> ProviderResult:
        session_id = input_data.get("session_id")
        if not isinstance(session_id, str):
            raise DomainError("VALIDATION_FAILED", "session_id is required")
        output: JsonObject = {
            "schema_version": "1.0",
            "post_id": new_id("post"),
            "session_id": session_id,
            "status": "queued",
            "output_asset_id": None,
            "publish_mode": "preview_only",
            "created_at": datetime.now(UTC).isoformat(),
        }
        return ProviderResult(
            output=output,
            confidence=1.0,
            model=self.model_name,
            warnings=["MOCK_JOB_QUEUED_NO_RENDERED_MEDIA"],
        )


class UnconfiguredProvider:
    name = "unconfigured"
    execution_mode = "live"

    async def invoke(
        self,
        skill_name: str,
        input_data: JsonObject,
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        raise DomainError(
            "PROVIDER_UNAVAILABLE",
            "No live model provider is configured and MOCK_AI_ENABLED is false",
            status_code=503,
            recoverable=True,
        )


class FixtureProvider(DeterministicMockProvider):
    """Public deterministic preset provider, explicitly labelled as Fixture."""

    name = "fixture"
    execution_mode = "fixture"


class SafeRuleFallbackProvider(DeterministicMockProvider):
    """Explicit low-confidence fallback for outputs that do not require media comparison."""

    name = "rule-fallback"
    execution_mode = "fallback"
    model_name = "safe-rules-v1"

    async def invoke(
        self,
        skill_name: str,
        input_data: JsonObject,
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        if skill_name == "result_evaluation":
            raise DomainError(
                "PROVIDER_UNAVAILABLE",
                "Rule fallback cannot compare capture media with a ShotPlan reliably",
                status_code=503,
                recoverable=True,
            )
        result = await super().invoke(
            skill_name,
            input_data,
            repair_error=repair_error,
        )
        output = dict(result.output)
        if "confidence" in output:
            output["confidence"] = min(float(output["confidence"]), 0.35)
        return replace(
            result,
            output=output,
            confidence=0.35,
            model=self.model_name,
            warnings=["RULE_FALLBACK_LOW_CONFIDENCE"],
        )
