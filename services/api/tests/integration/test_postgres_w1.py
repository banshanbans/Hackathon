from __future__ import annotations

import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from httpx import Response

from app.config import Settings
from app.main import create_app
from app.persistence.postgres import PostgresStateStore

pytestmark = pytest.mark.integration
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
FIXTURE_PATH = REPOSITORY_ROOT / "packages/contracts/fixtures/w1/closed-loop.json"


@pytest.mark.skipif(
    os.getenv("RUN_POSTGRES_TESTS") != "1",
    reason="set RUN_POSTGRES_TESTS=1 after running make migrate",
)
def test_postgres_persists_session_across_app_instances_and_cascades_delete() -> None:
    settings = Settings(model_provider="mock", mock_ai_enabled=True)
    unique = uuid4().hex
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    request = {
        "schema_version": "1.0",
        "source_channel": "demo_preset",
        "mode": "original_replication",
        "user_constraints": {
            "solo_traveler": True,
            "tripod_available": False,
            "has_luggage": False,
            "notes": "PostgreSQL integration test",
        },
    }
    with TestClient(create_app(PostgresStateStore(settings.database_url), settings)) as first:
        created = first.post(
            "/api/v1/sessions",
            headers={"Idempotency-Key": f"postgres-create-{unique}"},
            json=request,
        )
        assert created.status_code == 201
        session_id = created.json()["data"]["session_id"]
        analyzed = first.post(
            "/api/v1/references/analyze",
            headers={"Idempotency-Key": f"postgres-reference-{unique}"},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "reference_asset": fixture["reference_asset"],
            },
        )
        assert analyzed.status_code == 202
        planned = first.post(
            "/api/v1/agent/runs",
            headers={"Idempotency-Key": f"postgres-agent-{unique}"},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "intent": "original_replication",
            },
        )
        assert planned.status_code == 202
        run_id = planned.json()["data"]["run_id"]

        def create_round(suffix: str) -> Response:
            return first.post(
                "/api/v1/captures",
                headers={"Idempotency-Key": f"postgres-capture-{unique}-{suffix}"},
                json={
                    "schema_version": "1.0",
                    "session_id": session_id,
                    **fixture["capture"],
                    "media_asset_id": f"media_{suffix}",
                },
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            capture_attempts = list(executor.map(create_round, ("one", "two")))
        assert sorted(response.status_code for response in capture_attempts) == [201, 409]
        captured = next(response for response in capture_attempts if response.status_code == 201)
        capture_id = captured.json()["data"]["capture_id"]

    with TestClient(create_app(PostgresStateStore(settings.database_url), settings)) as second:
        restored = second.get(f"/api/v1/sessions/{session_id}")
        assert restored.status_code == 200
        assert restored.json()["data"]["state"] == "capturing"
        assert restored.json()["data"]["active_reference_analysis_id"] is not None
        continued = second.post(
            f"/api/v1/agent/runs/{run_id}/continue",
            headers={"Idempotency-Key": f"postgres-continue-{unique}"},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "capture_id": capture_id,
            },
        )
        assert continued.status_code == 202
        trace = second.get(f"/api/v1/agent/runs/{run_id}/trace")
        assert [item["skill"]["name"] for item in trace.json()["data"]["skill_runs"]] == [
            "shooting_plan",
            "result_evaluation",
            "content_composer",
        ]
        completed = second.get(f"/api/v1/sessions/{session_id}").json()["data"]
        assert completed["evaluation"]["issue_code"] == "person_too_large"
        assert completed["publish_package"]["status"] == "queued"
        sibling = second.post(
            "/api/v1/sessions",
            headers={"Idempotency-Key": f"postgres-shared-create-{unique}"},
            json=request,
        )
        assert sibling.status_code == 201
        sibling_id = sibling.json()["data"]["session_id"]
        sibling_analysis = second.post(
            "/api/v1/references/analyze",
            headers={"Idempotency-Key": f"postgres-shared-reference-{unique}"},
            json={
                "schema_version": "1.0",
                "session_id": sibling_id,
                "reference_asset": fixture["reference_asset"],
            },
        )
        assert sibling_analysis.status_code == 202
        deleted = second.delete(
            f"/api/v1/sessions/{session_id}",
            headers={"Idempotency-Key": f"postgres-delete-{unique}"},
        )
        assert deleted.status_code == 200
        assert second.get(f"/api/v1/sessions/{session_id}").status_code == 404
        sibling_restored = second.get(f"/api/v1/sessions/{sibling_id}")
        assert sibling_restored.status_code == 200
        assert sibling_restored.json()["data"]["active_reference_analysis_id"] is not None
        second.delete(
            f"/api/v1/sessions/{sibling_id}",
            headers={"Idempotency-Key": f"postgres-shared-cleanup-{unique}"},
        )
        recreated = second.post(
            "/api/v1/sessions",
            headers={"Idempotency-Key": f"postgres-create-{unique}"},
            json=request,
        )
        assert recreated.status_code == 201
        recreated_id = recreated.json()["data"]["session_id"]
        assert recreated_id != session_id
        second.delete(
            f"/api/v1/sessions/{recreated_id}",
            headers={"Idempotency-Key": f"postgres-cleanup-{unique}"},
        )
