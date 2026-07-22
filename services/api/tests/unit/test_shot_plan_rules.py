from __future__ import annotations

import asyncio
from time import perf_counter

import pytest

from app.domain.errors import DomainError
from app.domain.models import JsonObject, ReferenceAnalysis, ShotPlan, UserConstraints
from app.domain.shot_plan_rules import build_scene_adaptation_plan
from app.providers.base import ProviderResult
from app.skills.runtime import build_skills


def analysis(
    *,
    pose: str = "walking_turn",
    height: float = 0.62,
    center_x: float = 0.7,
    safety_status: str = "safe",
    warnings: list[str] | None = None,
    confidence: float = 0.88,
) -> ReferenceAnalysis:
    return ReferenceAnalysis.model_validate(
        {
            "schema_version": "1.0",
            "analysis_id": "ra_rules",
            "reference_id": "ref_rules",
            "person_count": 1,
            "target_layout": {
                "center_x": center_x,
                "center_y": 0.6,
                "width": 0.35,
                "height": height,
                "head_point": {"x": center_x, "y": 0.2},
                "foot_line_y": 0.92,
                "body_direction": "slightly_left",
                "pose_template": pose,
            },
            "composition_notes": ["模型自由文本不应被解析为规则。"],
            "safety_status": safety_status,
            "safety_warnings": warnings or [],
            "confidence": confidence,
        }
    )


def constraints(*, tripod: bool = False, luggage: bool = False) -> UserConstraints:
    return UserConstraints(
        solo_traveler=True,
        tripod_available=tripod,
        has_luggage=luggage,
        notes=None,
    )


def test_rule_plan_is_deterministic_fast_and_preserves_layout() -> None:
    source = analysis()
    started = perf_counter()
    first = build_scene_adaptation_plan(source, constraints(), plan_id="sp_rule_one")
    second = build_scene_adaptation_plan(source, constraints(), plan_id="sp_rule_two")

    assert perf_counter() - started < 1
    assert first.plan.target_layout == source.target_layout
    assert first.plan.capture_mode == "short_video"
    assert first.plan.camera_height == "waist"
    assert first.plan.lens == "1x"
    assert first.plan.camera_angle == "level"
    assert first.plan.confidence == source.confidence
    assert first.plan.model_dump(exclude={"plan_id"}) == second.plan.model_dump(
        exclude={"plan_id"}
    )
    assert "模型自由文本" not in first.plan.phone_setup_instruction


@pytest.mark.parametrize(
    ("pose", "height", "expected_height", "expected_mode"),
    [
        ("seated_drink", 0.6, "chest", "photo"),
        ("profile_closeup", 0.55, "chest", "photo"),
        ("standing_full_body", 0.6, "waist", "photo"),
        ("uncontrolled_new_pose", 0.6, "waist", "photo"),
        ("standing_full_body", 0.8, "chest", "photo"),
    ],
)
def test_rule_plan_uses_controlled_pose_families(
    pose: str, height: float, expected_height: str, expected_mode: str
) -> None:
    result = build_scene_adaptation_plan(
        analysis(pose=pose, height=height), constraints(), plan_id="sp_rule_family"
    )
    assert result.plan.camera_height == expected_height
    assert result.plan.capture_mode == expected_mode


def test_rule_plan_propagates_warn_and_blocks_unsafe_scene() -> None:
    warned = build_scene_adaptation_plan(
        analysis(safety_status="warn", warnings=["台阶湿滑，请先离开。"]),
        constraints(luggage=True),
        plan_id="sp_rule_warn",
    )
    assert warned.plan.safety_notes[0] == "台阶湿滑，请先离开。"
    assert any("行李" in note for note in warned.plan.safety_notes)
    assert "SCENE_SAFETY_WARNING_PROPAGATED" in warned.warnings

    with pytest.raises(DomainError) as blocked:
        build_scene_adaptation_plan(
            analysis(safety_status="block", warnings=["现场靠近行车道。"]),
            constraints(),
            plan_id="sp_rule_block",
        )
    assert blocked.value.code == "UNSAFE_INSTRUCTION"


class RecordingProvider:
    name = "recording-model"
    execution_mode = "live"

    def __init__(self) -> None:
        self.calls: list[str] = []

    async def invoke(
        self,
        skill_name: str,
        input_data: JsonObject,
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        self.calls.append(skill_name)
        if skill_name == "scene_adaptation":
            output = analysis().model_dump(mode="json")
        elif skill_name == "shooting_plan":
            output = build_scene_adaptation_plan(
                analysis(pose="standing_full_body"),
                constraints(),
                plan_id="sp_model_original",
            ).plan.model_dump(mode="json")
        else:
            raise AssertionError(f"unexpected model call: {skill_name}")
        return ProviderResult(output=output, confidence=0.88, model="visual-model")


def reference_asset() -> JsonObject:
    return {
        "schema_version": "1.0",
        "reference_id": "ref_rules",
        "media_asset_id": None,
        "media_type": "image",
        "source_type": "preset",
        "width": 100,
        "height": 100,
        "selected_box": {"x": 0.2, "y": 0.1, "width": 0.5, "height": 0.8},
        "attribution": {"source_label": "fixture", "creator_label": None},
    }


def test_scene_rule_skill_does_not_make_a_second_model_call() -> None:
    provider = RecordingProvider()
    skills = build_skills(provider, timeout_seconds=8, scene_adaptation_timeout_seconds=35)
    adapted = asyncio.run(
        skills[("scene_adaptation", "1.0.0")].invoke(
            {
                "reference_asset": reference_asset(),
                "reference_analysis": analysis().model_dump(mode="json"),
                "scene_asset_id": "media_scene",
                "user_constraints": constraints().model_dump(mode="json"),
            }
        )
    )
    planned = asyncio.run(
        skills[("shooting_plan", "1.1.0")].invoke(
            {
                "reference_asset": reference_asset(),
                "reference_analysis": adapted.output,
                "user_constraints": constraints().model_dump(mode="json"),
                "mode": "scene_adaptation",
                "scene_asset_id": "media_scene",
            }
        )
    )

    assert provider.calls == ["scene_adaptation"]
    assert planned.run.skill.version == "1.1.0"
    assert planned.run.provider == "server-rules-v1"
    assert planned.run.model is None
    assert planned.run.latency_ms < 1_000
    assert planned.run.estimated_cost_usd == 0
    assert planned.run.fallback_used is False
    ShotPlan.model_validate(planned.output)


def test_original_replication_keeps_model_shooting_plan() -> None:
    provider = RecordingProvider()
    skills = build_skills(provider, timeout_seconds=8)
    invocation = asyncio.run(
        skills[("shooting_plan", "1.0.0")].invoke(
            {
                "reference_asset": reference_asset(),
                "reference_analysis": analysis().model_dump(mode="json"),
                "user_constraints": constraints().model_dump(mode="json"),
                "mode": "original_replication",
            }
        )
    )
    assert provider.calls == ["shooting_plan"]
    assert invocation.run.skill.version == "1.0.0"
    assert invocation.run.model == "visual-model"
