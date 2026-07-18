from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

from app.providers.mock import DeterministicMockProvider
from app.skills.registry import SkillRegistry
from app.skills.runtime import build_skills

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
PROMPT_ROOT = REPOSITORY_ROOT / "packages/prompts"
FIXTURE_PATH = REPOSITORY_ROOT / "packages/contracts/fixtures/w1/closed-loop.json"
SKILLS = (
    "reference_understanding",
    "scene_adaptation",
    "shooting_plan",
    "result_evaluation",
    "content_composer",
)


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def test_each_versioned_skill_has_prompt_evaluation_assets() -> None:
    required = {
        "manifest.json",
        "system.md",
        "schema.json",
        "examples.json",
        "eval-cases.json",
        "changelog.md",
    }
    for skill_name in SKILLS:
        directory = PROMPT_ROOT / skill_name / "1.0.0"
        assert {path.name for path in directory.iterdir()} >= required
        manifest = load_json(directory / "manifest.json")
        assert manifest["name"] == skill_name
        assert manifest["version"] == "1.0.0"
        assert manifest["timeout_seconds"] == 8
        assert manifest["max_repairs"] == 1
        assert manifest["fallback"]


def test_mock_outputs_keep_evaluation_and_content_honest() -> None:
    fixture = load_json(FIXTURE_PATH)
    registry = SkillRegistry(build_skills(DeterministicMockProvider(), 8))
    reference = asyncio.run(
        registry.get("reference_understanding").invoke(
            {"reference_asset": fixture["reference_asset"]}
        )
    )
    plan = asyncio.run(
        registry.get("shooting_plan").invoke(
            {
                "reference_asset": fixture["reference_asset"],
                "reference_analysis": reference.output,
                "user_constraints": fixture["session"]["user_constraints"],
                "mode": "original_replication",
            }
        )
    )
    capture = {
        "schema_version": "1.0",
        "capture_id": "cap_eval_fixture",
        "session_id": "ss_eval_fixture",
        "round_index": 1,
        "media_asset_id": fixture["capture"]["media_asset_id"],
        "status": "ready",
        "selected_frame_id": None,
        "created_at": "2026-07-17T00:00:00Z",
    }
    evaluation = asyncio.run(
        registry.get("result_evaluation").invoke(
            {
                "reference_asset": fixture["reference_asset"],
                "reference_analysis": reference.output,
                "scene_asset_id": None,
                "capture": capture,
                "shot_plan": plan.output,
                "mode": "original_replication",
            }
        )
    )
    content = asyncio.run(
        registry.get("content_composer").invoke(
            {"session_id": "ss_eval_fixture", "format": "before_after_image"}
        )
    )

    assert evaluation.output["issue_code"] == "person_too_large"
    assert evaluation.output["needs_retake"] is True
    assert content.output["status"] == "queued"
    assert content.output["output_asset_id"] is None
    assert all(run.execution_mode == "mock" for run in (reference, plan, evaluation, content))


def test_scene_adaptation_eval_cases_cover_safe_warn_and_block() -> None:
    cases = json.loads(
        (PROMPT_ROOT / "scene_adaptation/1.0.0/eval-cases.json").read_text(encoding="utf-8")
    )
    assert isinstance(cases, list)
    statuses = {case["expects"]["safety_status"] for case in cases}

    assert statuses == {"safe", "warn", "block"}
    for case in cases:
        if case["expects"]["safety_status"] != "safe":
            assert case["expects"]["warning_required"] is True
