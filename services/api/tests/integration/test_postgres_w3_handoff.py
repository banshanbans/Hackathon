from __future__ import annotations

import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from httpx import Response

from app.config import Settings
from app.main import create_app
from app.persistence.postgres import PostgresStateStore

pytestmark = pytest.mark.integration
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
MANIFEST_PATH = REPOSITORY_ROOT / "packages/evals/test-image-v1/manifest.json"


def headers(name: str) -> dict[str, str]:
    return {"Idempotency-Key": f"postgres-w3-{name}-{uuid4()}"}


def prepare_plan(api: TestClient) -> dict[str, Any]:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    reference = next(item for item in manifest["cases"] if item["public_preset"])[
        "reference_asset"
    ]
    created = api.post(
        "/api/v1/sessions",
        headers=headers("session"),
        json={
            "schema_version": "1.0",
            "source_channel": "demo_preset",
            "mode": "original_replication",
            "external_ai_consent": False,
            "user_constraints": {
                "solo_traveler": True,
                "tripod_available": False,
                "has_luggage": False,
                "notes": "PostgreSQL W3 atomic claim test",
            },
        },
    )
    assert created.status_code == 201
    session_id = created.json()["data"]["session_id"]
    assert api.post(
        "/api/v1/references/analyze",
        headers=headers("reference"),
        json={
            "schema_version": "1.0",
            "session_id": session_id,
            "reference_asset": reference,
        },
    ).status_code == 202
    assert api.post(
        "/api/v1/agent/runs",
        headers=headers("plan"),
        json={
            "schema_version": "1.0",
            "session_id": session_id,
            "intent": "original_replication",
        },
    ).status_code == 202
    return api.get(f"/api/v1/sessions/{session_id}").json()["data"]


@pytest.mark.skipif(
    os.getenv("RUN_POSTGRES_TESTS") != "1",
    reason="set RUN_POSTGRES_TESTS=1 after running make migrate",
)
def test_postgres_handoff_claim_is_atomic_and_cascades() -> None:
    settings = Settings(
        model_provider="hybrid",
        app_env="test",
        handoff_discovery_enabled=True,
    )
    with TestClient(create_app(PostgresStateStore(settings.database_url), settings)) as api:
        session = prepare_plan(api)
        created = api.post(
            "/api/v1/handoffs",
            headers=headers("create"),
            json={
                "schema_version": "1.0",
                "session_id": session["session_id"],
            },
        )
        assert created.status_code == 201
        code = created.json()["data"]["handoff"]["code"]

        available = api.get("/api/v1/handoffs")
        assert available.status_code == 200
        assert [item["code"] for item in available.json()["data"]["items"]] == [code]

        public = api.get(f"/api/v1/handoffs/{code}")
        public_text = json.dumps(public.json())
        assert public.status_code == 200
        assert session["session_id"] not in public_text
        assert session["shot_plan"]["plan_id"] not in public_text

        def claim(index: int) -> Response:
            return api.post(
                f"/api/v1/handoffs/{code}/claim",
                headers=headers(f"claim-{index}"),
                json={
                    "schema_version": "1.0",
                    "client_instance_id": f"postgres-ios-{index:08d}",
                },
            )

        with ThreadPoolExecutor(max_workers=4) as executor:
            outcomes = list(executor.map(claim, range(4)))
        assert sorted(item.status_code for item in outcomes) == [200, 409, 409, 409]
        winner = next(item for item in outcomes if item.status_code == 200).json()["data"]
        assert winner["session"]["shot_plan"]["plan_id"] == session["shot_plan"]["plan_id"]
        assert api.get("/api/v1/handoffs").json()["data"]["items"] == []

        deleted = api.delete(
            f"/api/v1/sessions/{session['session_id']}",
            headers=headers("delete"),
        )
        assert deleted.status_code == 200
        assert api.get(f"/api/v1/handoffs/{code}").status_code == 404
