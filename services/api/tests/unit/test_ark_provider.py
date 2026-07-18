from __future__ import annotations

import asyncio
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
    assert media_asset_id in {"media_ark_reference", "media_ark_scene"}
    return "image/jpeg", b"verified-image-bytes"


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
