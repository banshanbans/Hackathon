from __future__ import annotations

import asyncio
import base64
import json
from typing import Any

import httpx
import pytest

from app.domain.errors import DomainError
from app.providers.ark import VolcengineArkProvider
from app.skills.registry import SkillRegistry
from app.skills.runtime import build_skills


def reference_asset() -> dict[str, Any]:
    return {
        "schema_version": "1.0",
        "reference_id": "ref_ark_test",
        "media_asset_id": "media_ark_reference",
        "media_type": "image",
        "source_type": "upload",
        "width": 12,
        "height": 8,
        "selected_box": {"x": 0.2, "y": 0.1, "width": 0.5, "height": 0.8},
        "attribution": {"source_label": "user selected local media"},
    }


def analysis_output() -> dict[str, Any]:
    return {
        "schema_version": "1.0",
        "analysis_id": "ra_ark_test",
        "reference_id": "ref_ark_test",
        "person_count": 1,
        "target_layout": {
            "center_x": 0.45,
            "center_y": 0.55,
            "width": 0.4,
            "height": 0.75,
            "head_point": {"x": 0.45, "y": 0.18},
            "foot_line_y": 0.92,
            "body_direction": "slightly_left",
            "pose_template": "standing_turn",
        },
        "composition_notes": ["保留背景纵深。"],
        "safety_status": "safe",
        "safety_warnings": [],
        "confidence": 0.89,
    }


async def media_loader(media_asset_id: str) -> tuple[str, bytes]:
    assert media_asset_id in {
        "media_ark_reference",
        "media_ark_scene",
        "media_ark_previous",
        "media_ark_current",
    }
    return "image/jpeg", media_asset_id.encode()


def provider_with_handler(
    handler: httpx.MockTransport,
) -> VolcengineArkProvider:
    return VolcengineArkProvider(
        api_key="test-only-api-key",
        model_id="test-endpoint-id",
        base_url="https://ark.example.test/api/v3",
        timeout_seconds=2,
        media_loader=media_loader,
        client=httpx.AsyncClient(transport=handler),
    )


def test_ark_sends_verified_media_as_data_url_and_requests_json_schema() -> None:
    captured: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["authorization"] = request.headers.get("Authorization")
        captured["payload"] = json.loads(request.content)
        return httpx.Response(200, json={"output_text": json.dumps(analysis_output())})

    provider = provider_with_handler(httpx.MockTransport(handler))
    result = asyncio.run(
        provider.invoke(
            "reference_understanding",
            {"reference_asset": reference_asset()},
        )
    )

    assert result.output == analysis_output()
    assert result.execution_mode == "live"
    assert result.provider_name == "volcengine-ark"
    assert captured["authorization"] == "Bearer test-only-api-key"
    payload = captured["payload"]
    assert payload["model"] == "test-endpoint-id"
    assert payload["store"] is False
    assert payload["text"]["format"]["type"] == "json_schema"
    content = payload["input"][0]["content"]
    assert content[0]["type"] == "input_image"
    assert content[0]["image_url"].startswith("data:image/jpeg;base64,")
    assert content[-1]["type"] == "input_text"


def test_ark_falls_back_to_json_text_when_schema_format_is_explicitly_unsupported() -> None:
    calls: list[dict[str, Any]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        calls.append(payload)
        if len(calls) == 1:
            return httpx.Response(400, text="json_schema in text.format is unsupported")
        return httpx.Response(200, json={"output_text": json.dumps(analysis_output())})

    provider = provider_with_handler(httpx.MockTransport(handler))
    result = asyncio.run(
        provider.invoke("reference_understanding", {"reference_asset": reference_asset()})
    )

    assert len(calls) == 2
    assert "text" in calls[0]
    assert "text" not in calls[1]
    assert "ARK_JSON_SCHEMA_UNAVAILABLE" in result.warnings


def test_skill_runtime_repairs_ark_output_once_and_strictly_validates_result() -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        output = {} if calls == 1 else analysis_output()
        return httpx.Response(200, json={"output_text": json.dumps(output)})

    provider = provider_with_handler(httpx.MockTransport(handler))
    registry = SkillRegistry(build_skills(provider, 2))
    invocation = asyncio.run(
        registry.get("reference_understanding").invoke(
            {"reference_asset": reference_asset()}
        )
    )

    assert calls == 2
    assert invocation.run.repair_count == 1
    assert "STRUCTURED_OUTPUT_REPAIRED_ONCE" in invocation.run.warnings
    assert invocation.output["analysis_id"] == "ra_ark_test"


@pytest.mark.parametrize(
    ("status", "expected_code"),
    [(401, "PROVIDER_UNAVAILABLE"), (422, "PROVIDER_REJECTED")],
)
def test_ark_maps_auth_rate_and_content_rejection_to_stable_errors(
    status: int, expected_code: str
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(status, text="rejected")

    provider = provider_with_handler(httpx.MockTransport(handler))
    with pytest.raises(DomainError) as caught:
        asyncio.run(
            provider.invoke("reference_understanding", {"reference_asset": reference_asset()})
        )
    assert caught.value.code == expected_code
    assert caught.value.recoverable is True


def test_ark_timeout_and_missing_configuration_fail_without_fixture_output() -> None:
    def timeout_handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timeout", request=request)

    provider = provider_with_handler(httpx.MockTransport(timeout_handler))
    with pytest.raises(DomainError) as timeout:
        asyncio.run(
            provider.invoke("reference_understanding", {"reference_asset": reference_asset()})
        )
    assert timeout.value.code == "MODEL_TIMEOUT"

    unconfigured = VolcengineArkProvider(
        api_key="",
        model_id="",
        base_url="https://ark.example.test/api/v3",
        timeout_seconds=2,
        media_loader=media_loader,
        client=httpx.AsyncClient(transport=httpx.MockTransport(timeout_handler)),
    )
    with pytest.raises(DomainError) as missing:
        asyncio.run(
            unconfigured.invoke(
                "reference_understanding", {"reference_asset": reference_asset()}
            )
        )
    assert missing.value.code == "PROVIDER_UNAVAILABLE"


def test_round_two_uses_previous_then_current_selected_frame_and_repairs_motion_claim() -> None:
    payloads: list[dict[str, Any]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        payloads.append(json.loads(request.content))
        if len(payloads) == 1:
            output = evaluation_output(issue_code="motion_timing_wrong")
        else:
            output = evaluation_output(issue_code="person_too_left")
        return httpx.Response(200, json={"output_text": json.dumps(output)})

    provider = provider_with_handler(httpx.MockTransport(handler))
    registry = SkillRegistry(build_skills(provider, 2))
    invocation = asyncio.run(
        registry.get("result_evaluation").invoke(round_two_evaluation_input())
    )

    assert len(payloads) == 2
    assert invocation.run.repair_count == 1
    assert "STRUCTURED_OUTPUT_REPAIRED_ONCE" in invocation.run.warnings
    assert invocation.output["issue_code"] == "person_too_left"
    content = payloads[0]["input"][0]["content"]
    images = [item["image_url"] for item in content if item["type"] == "input_image"]
    decoded = [base64.b64decode(value.split(",", 1)[1]).decode() for value in images]
    assert decoded == ["media_ark_reference", "media_ark_previous", "media_ark_current"]


def evaluation_output(*, issue_code: str) -> dict[str, Any]:
    return {
        "schema_version": "1.0",
        "evaluation_id": "eval_ark_round_2",
        "capture_id": "cap_ark_current",
        "issue_code": issue_code,
        "top_issue": "只修正当前最重要的问题。",
        "next_instruction": "由服务端规则覆盖",
        "needs_retake": True,
        "goal_satisfied": False,
        "publish_readiness": 0.7,
        "confidence": 0.8,
        "execution_mode": "live",
    }


def round_two_evaluation_input() -> dict[str, Any]:
    plan = {
        "schema_version": "1.0",
        "plan_id": "sp_ark_test",
        "camera_height": "waist",
        "camera_angle": "level",
        "lens": "1x",
        "capture_mode": "photo",
        "phone_setup_instruction": "固定手机。",
        "target_layout": analysis_output()["target_layout"],
        "action_script": [
            {"sequence": 1, "instruction": "站稳。", "duration_seconds": 2}
        ],
        "safety_notes": ["检查脚下。"],
        "h5_execution": {
            "supported": True,
            "instruction": "静态构图。",
            "requires_realtime_alignment": False,
        },
        "ios_execution": {
            "supported": True,
            "instruction": "本地对齐。",
            "requires_realtime_alignment": True,
        },
        "confidence": 0.9,
    }
    previous_capture = {
        "schema_version": "1.0",
        "capture_id": "cap_ark_previous",
        "session_id": "ss_ark_test",
        "round_index": 1,
        "media_asset_id": "media_ark_previous",
        "status": "ready",
        "selected_frame_id": "frame_ark_previous",
        "created_at": "2026-07-19T00:00:00Z",
    }
    current_capture = {
        **previous_capture,
        "capture_id": "cap_ark_current",
        "round_index": 2,
        "media_asset_id": "media_ark_current",
        "selected_frame_id": "frame_ark_current",
    }
    previous_evaluation = evaluation_output(issue_code="person_too_left")
    previous_evaluation["evaluation_id"] = "eval_ark_round_1"
    previous_evaluation["capture_id"] = "cap_ark_previous"
    return {
        "reference_asset": reference_asset(),
        "reference_analysis": analysis_output(),
        "scene_asset_id": None,
        "capture": current_capture,
        "previous_capture": previous_capture,
        "previous_evaluation": previous_evaluation,
        "shot_plan": plan,
        "mode": "original_replication",
        "media_kind": "selected_frame",
        "round_index": 2,
    }
