from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.persistence.store import MemoryStateStore

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
FIXTURE_PATH = REPOSITORY_ROOT / "packages/contracts/fixtures/w1/closed-loop.json"


def fixture() -> dict[str, Any]:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def client() -> TestClient:
    settings = Settings(model_provider="mock", mock_ai_enabled=True)
    return TestClient(create_app(MemoryStateStore(), settings))


def key(name: str) -> dict[str, str]:
    return {"Idempotency-Key": f"w1-test-{name}"}


def test_w1_closed_loop_has_ordered_trace_and_honest_job() -> None:
    data = fixture()
    with client() as api:
        created = api.post(
            "/api/v1/sessions",
            headers=key("session"),
            json={"schema_version": "1.0", **data["session"]},
        )
        assert created.status_code == 201
        session = created.json()["data"]
        assert session["state"] == "created"
        assert session["reference_asset"] is None
        session_id = session["session_id"]

        analyzed = api.post(
            "/api/v1/references/analyze",
            headers=key("reference"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "reference_asset": data["reference_asset"],
            },
        )
        assert analyzed.status_code == 202
        assert analyzed.headers["X-SoloShot-Execution-Mode"] == "mock"
        assert analyzed.json()["data"]["person_count"] == 1
        reference_id = analyzed.json()["data"]["reference_id"]
        reference = api.get(f"/api/v1/references/{reference_id}")
        assert reference.status_code == 200
        assert reference.json()["data"] == {
            **data["reference_asset"],
            "media_asset_id": None,
        }
        validated = api.post(
            "/api/v1/references/validate-box",
            headers=key("reference-box"),
            json={
                "schema_version": "1.0",
                "reference_id": reference_id,
                "selected_box": data["reference_asset"]["selected_box"],
            },
        )
        assert validated.status_code == 200
        assert validated.json()["data"]["valid"] is True
        cached = api.post(
            "/api/v1/references/analyze",
            headers=key("reference"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "reference_asset": data["reference_asset"],
            },
        )
        assert cached.status_code == 202
        assert cached.headers["X-SoloShot-Execution-Mode"] == "cache"
        assert cached.json()["data"] == analyzed.json()["data"]

        planned = api.post(
            "/api/v1/agent/runs",
            headers=key("agent"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "intent": "original_replication",
            },
        )
        assert planned.status_code == 202
        run_id = planned.json()["data"]["run_id"]
        assert [item["name"] for item in planned.json()["data"]["selected_skills"]] == [
            "shooting_plan",
        ]
        assert planned.json()["data"]["provider"] == "mock"
        assert planned.json()["data"]["model"] == "test-image-fixture-v1"
        assert planned.json()["data"]["estimated_cost_usd"] == 0
        assert api.get(f"/api/v1/agent/runs/{run_id}").json()["data"] == planned.json()["data"]

        captured = api.post(
            "/api/v1/captures",
            headers=key("capture"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                **data["capture"],
            },
        )
        assert captured.status_code == 201
        capture_id = captured.json()["data"]["capture_id"]
        assert api.get(f"/api/v1/captures/{capture_id}").status_code == 200
        selected = api.post(
            f"/api/v1/captures/{capture_id}/select-frame",
            headers=key("select-frame"),
            json={"schema_version": "1.0", "frame_id": "frame_best"},
        )
        assert selected.status_code == 200
        assert selected.json()["data"]["selected_frame_id"] == "frame_best"
        session_after_selection = api.get(f"/api/v1/sessions/{session_id}").json()["data"]
        assert session_after_selection["capture_rounds"][-1]["selected_frame_id"] == "frame_best"
        premature_round = api.post(
            "/api/v1/captures",
            headers=key("capture-round-2-too-early"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "round_index": 2,
                "media_asset_id": "media_too_early",
            },
        )
        assert premature_round.status_code == 409
        assert premature_round.json()["error"]["code"] == "INVALID_STATE"

        continued = api.post(
            f"/api/v1/agent/runs/{run_id}/continue",
            headers=key("continue"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "capture_id": capture_id,
            },
        )
        assert continued.status_code == 202
        assert [item["name"] for item in continued.json()["data"]["selected_skills"]] == [
            "shooting_plan",
            "result_evaluation",
            "content_composer",
        ]

        trace = api.get(f"/api/v1/agent/runs/{run_id}/trace")
        assert trace.status_code == 200
        assert trace.headers["X-SoloShot-Execution-Mode"] == "mock"
        skill_runs = trace.json()["data"]["skill_runs"]
        assert [item["skill"]["name"] for item in skill_runs] == [
            "shooting_plan",
            "result_evaluation",
            "content_composer",
        ]
        assert all(item["provider"] == "mock" for item in skill_runs)
        assert all(item["estimated_cost_usd"] == 0 for item in skill_runs)
        assert all("MOCK" in item["warnings"][0] for item in skill_runs)

        final_session = api.get(f"/api/v1/sessions/{session_id}")
        assert final_session.status_code == 200
        result = final_session.json()["data"]
        assert result["state"] == "coaching"
        assert result["evaluation"]["issue_code"] == "person_too_large"
        assert result["evaluation"]["next_instruction"] == "后退两步，其他动作保持不变"
        assert result["publish_package"]["status"] == "queued"
        assert result["publish_package"]["output_asset_id"] is None
        assert result["publish_package"]["publish_mode"] == "preview_only"
        post_id = result["publish_package"]["post_id"]
        assert api.get(f"/api/v1/posts/{post_id}").json()["data"] == result["publish_package"]

        skill_cases = {
            "reference_understanding": {
                "reference_asset": data["reference_asset"],
            },
            "shooting_plan": {
                "reference_asset": {
                    **data["reference_asset"],
                    "media_asset_id": None,
                },
                "reference_analysis": analyzed.json()["data"],
                "user_constraints": data["session"]["user_constraints"],
                "mode": "original_replication",
            },
            "result_evaluation": {
                "reference_asset": {
                    **data["reference_asset"],
                    "media_asset_id": None,
                },
                "reference_analysis": analyzed.json()["data"],
                "capture": selected.json()["data"],
                "shot_plan": result["shot_plan"],
                "mode": "original_replication",
            },
            "content_composer": {
                "session_id": session_id,
                "format": "before_after_image",
            },
        }
        for skill_name, skill_input in skill_cases.items():
            invoked = api.post(
                f"/api/v1/skills/{skill_name}/invoke",
                headers=key(f"invoke-{skill_name}"),
                json={
                    "schema_version": "1.0",
                    "session_id": session_id,
                    "skill_version": "1.0.0",
                    "input": skill_input,
                },
            )
            assert invoked.status_code == 202
            assert invoked.json()["data"]["run"]["skill"]["name"] == skill_name
            assert invoked.json()["data"]["output"]["schema_version"] == "1.0"

        second_capture = api.post(
            "/api/v1/captures",
            headers=key("capture-round-2"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "round_index": 2,
                "media_asset_id": "media_round_2",
            },
        )
        assert second_capture.status_code == 201
        second_capture_id = second_capture.json()["data"]["capture_id"]
        evaluated = api.post(
            "/api/v1/evaluations",
            headers=key("evaluation-round-2"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "capture_id": second_capture_id,
            },
        )
        assert evaluated.status_code == 202
        assert evaluated.json()["data"]["capture_id"] == second_capture_id
        rendered = api.post(
            "/api/v1/posts/render",
            headers=key("render-round-2"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "format": "before_after_image",
            },
        )
        assert rendered.status_code == 202
        assert rendered.json()["data"]["status"] == "queued"
        assert rendered.json()["data"]["output_asset_id"] is None
        unsupported_render = api.post(
            "/api/v1/posts/render",
            headers=key("render-video-unsupported"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "format": "vertical_video",
            },
        )
        assert unsupported_render.status_code == 404
        assert unsupported_render.json()["error"]["code"] == "SKILL_NOT_FOUND"


def test_idempotency_replays_resource_and_rejects_changed_payload() -> None:
    data = fixture()
    request = {"schema_version": "1.0", **data["session"]}
    with client() as api:
        first = api.post("/api/v1/sessions", headers=key("same"), json=request)
        second = api.post("/api/v1/sessions", headers=key("same"), json=request)
        assert first.status_code == second.status_code == 201
        assert first.json()["data"] == second.json()["data"]
        assert first.json()["request_id"] != second.json()["request_id"]

        changed = {**request, "mode": "scene_adaptation"}
        conflict = api.post("/api/v1/sessions", headers=key("same"), json=changed)
        assert conflict.status_code == 409
        assert conflict.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"
        assert conflict.json()["error"]["request_id"] == conflict.headers["X-Request-ID"]


def test_invalid_state_and_unsupported_skill_are_stable_errors() -> None:
    data = fixture()
    with client() as api:
        created = api.post(
            "/api/v1/sessions",
            headers=key("errors-session"),
            json={"schema_version": "1.0", **data["session"]},
        )
        session_id = created.json()["data"]["session_id"]
        capture = api.post(
            "/api/v1/captures",
            headers=key("errors-capture"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                **data["capture"],
            },
        )
        assert capture.status_code == 409
        assert capture.json()["error"]["code"] == "INVALID_STATE"

        missing_skill = api.post(
                "/api/v1/skills/coaching_decision/invoke",
            headers=key("errors-skill"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "skill_version": "1.0.0",
                "input": {},
            },
        )
        assert missing_skill.status_code == 404
        assert missing_skill.json()["error"]["code"] == "SKILL_NOT_FOUND"


def test_session_delete_removes_owned_state() -> None:
    data = fixture()
    with client() as api:
        created = api.post(
            "/api/v1/sessions",
            headers=key("delete-session"),
            json={"schema_version": "1.0", **data["session"]},
        )
        session_id = created.json()["data"]["session_id"]
        deleted = api.delete(f"/api/v1/sessions/{session_id}", headers=key("delete-action"))
        assert deleted.status_code == 200
        assert deleted.json()["data"]["deleted"] is True
        assert api.get(f"/api/v1/sessions/{session_id}").status_code == 404


def test_unsupported_schema_version_has_specific_error() -> None:
    data = fixture()
    with client() as api:
        response = api.post(
            "/api/v1/sessions",
            headers=key("schema-version"),
            json={"schema_version": "2.0", **data["session"]},
        )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "SCHEMA_VERSION_UNSUPPORTED"
