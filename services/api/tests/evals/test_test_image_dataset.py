from __future__ import annotations

import asyncio
import hashlib
import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

from app.domain.models import ReferenceAsset, ResultEvaluation, ShotPlan
from app.providers.mock import DeterministicMockProvider
from app.skills.registry import SkillRegistry
from app.skills.runtime import build_skills

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
DATASET_ROOT = REPOSITORY_ROOT / "packages/evals/test-image-v1"
MANIFEST_PATH = DATASET_ROOT / "manifest.json"
SCHEMA_PATH = DATASET_ROOT / "manifest.schema.json"
PUBLIC_ROOT = REPOSITORY_ROOT / "apps/h5/public/presets/test-image-v1"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def jpeg_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    index = 2
    while index + 9 < len(data):
        if data[index] != 0xFF:
            index += 1
            continue
        marker = data[index + 1]
        if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB}:
            return (
                int.from_bytes(data[index + 7 : index + 9], "big"),
                int.from_bytes(data[index + 5 : index + 7], "big"),
            )
        if marker in {0xD8, 0xD9}:
            index += 2
            continue
        segment_length = int.from_bytes(data[index + 2 : index + 4], "big")
        index += 2 + segment_length
    raise AssertionError(f"Could not read JPEG dimensions for {path}")


def webp_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    kind = data[12:16]
    if kind == b"VP8 ":
        assert data[23:26] == b"\x9d\x01\x2a"
        width = int.from_bytes(data[26:28], "little") & 0x3FFF
        height = int.from_bytes(data[28:30], "little") & 0x3FFF
        return width, height
    if kind == b"VP8X":
        width = 1 + int.from_bytes(data[24:27], "little")
        height = 1 + int.from_bytes(data[27:30], "little")
        return width, height
    if kind == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    raise AssertionError(f"Unsupported WebP chunk {kind!r}")


def test_manifest_assets_and_public_derivatives_are_stable() -> None:
    manifest = load_json(MANIFEST_PATH)
    schema = load_json(SCHEMA_PATH)
    Draft202012Validator(schema).validate(manifest)

    cases = manifest["cases"]
    assert len(cases) == 8
    assert len({case["case_id"] for case in cases}) == 8
    assert len({case["reference_id"] for case in cases}) == 8
    public_cases = [case for case in cases if case["public_preset"]]
    assert [case["case_id"] for case in public_cases] == [
        "doorway_coffee_fullbody",
        "stone_village_lean",
        "storefront_profile",
        "cafe_seated_drink",
    ]

    for case in cases:
        source = DATASET_ROOT / case["source_path"]
        assert source.is_file()
        assert hashlib.sha256(source.read_bytes()).hexdigest() == case["sha256"]
        assert jpeg_dimensions(source) == (case["width"], case["height"])
        asset = ReferenceAsset.model_validate(case["reference_asset"])
        assert asset.reference_id == case["reference_id"]
        assert asset.width == case["width"] and asset.height == case["height"]
        assert asset.attribution.source_label == manifest["rights"]["source_label"]

        if case["public_preset"]:
            for kind, suffix, budget in (
                ("thumbnail", "thumb", 80 * 1024),
                ("detail", "detail", 300 * 1024),
            ):
                asset_path = PUBLIC_ROOT / f"{case['case_id']}-{suffix}.webp"
                assert case["public_assets"][kind].endswith(asset_path.name)
                assert asset_path.is_file() and asset_path.stat().st_size <= budget
                width, height = webp_dimensions(asset_path)
                if kind == "thumbnail":
                    assert width <= 320 and height <= case["height"]
                else:
                    assert max(width, height) <= 960
                assert width <= case["width"] and height <= case["height"]
        else:
            assert "public_assets" not in case


def test_all_reference_fixtures_and_public_closed_loops_match_expectations() -> None:
    manifest = load_json(MANIFEST_PATH)
    provider = DeterministicMockProvider(MANIFEST_PATH)
    registry = SkillRegistry(build_skills(provider, 8))
    constraints = {
        "solo_traveler": True,
        "tripod_available": False,
        "has_luggage": False,
        "notes": None,
    }

    for case in manifest["cases"]:
        reference = asyncio.run(
            registry.get("reference_understanding").invoke(
                {"reference_asset": case["reference_asset"]}
            )
        )
        assert reference.output["person_count"] == case["expected_reference"]["person_count"]
        assert reference.output["target_layout"] == case["expected_reference"]["target_layout"]
        assert reference.output["confidence"] == case["expected_reference"]["confidence"]
        assert provider.dataset_version in reference.run.warnings[0]
        assert f"case_id={case['case_id']}" in reference.run.warnings[0]

        plan = asyncio.run(
            registry.get("shooting_plan").invoke(
                {
                    "reference_asset": case["reference_asset"],
                    "reference_analysis": reference.output,
                    "user_constraints": constraints,
                    "mode": "original_replication",
                }
            )
        )
        ShotPlan.model_validate(plan.output)
        assert plan.output["target_layout"] == reference.output["target_layout"]
        assert plan.output["safety_notes"]

        if not case["public_preset"]:
            continue
        evaluations: list[ResultEvaluation] = []
        for expected in case["result_evaluations"]:
            round_index = expected["round_index"]
            invocation = asyncio.run(
                registry.get("result_evaluation").invoke(
                    {
                        "reference_asset": case["reference_asset"],
                        "reference_analysis": reference.output,
                        "scene_asset_id": None,
                        "capture": {
                            "schema_version": "1.0",
                            "capture_id": f"cap_{case['case_id']}_{round_index}",
                            "session_id": f"ss_{case['case_id']}",
                            "round_index": round_index,
                            "media_asset_id": (
                                f"media_fixture_{case['case_id']}_round_{round_index}"
                            ),
                            "status": "ready",
                            "selected_frame_id": None,
                            "created_at": "2026-07-17T00:00:00Z",
                        },
                        "shot_plan": plan.output,
                        "mode": "original_replication",
                    }
                )
            )
            evaluations.append(ResultEvaluation.model_validate(invocation.output))
        assert evaluations[0].needs_retake is True
        assert evaluations[0].issue_code == case["result_evaluations"][0]["issue_code"]
        assert evaluations[1].goal_satisfied is True
        assert evaluations[1].needs_retake is False
        assert evaluations[1].issue_code is None
