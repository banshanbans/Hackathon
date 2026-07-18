from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import uuid4

from fastapi.testclient import TestClient

from app.config import Settings
from app.domain.errors import DomainError
from app.handoff.rate_limit import RedisHandoffRateLimiter
from app.main import create_app
from app.persistence.store import MemoryStateStore

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
MANIFEST_PATH = REPOSITORY_ROOT / "packages/evals/test-image-v1/manifest.json"


def headers(name: str) -> dict[str, str]:
    return {"Idempotency-Key": f"w3-{name}-{uuid4()}"}


def fixture_case() -> dict[str, Any]:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    return next(item for item in manifest["cases"] if item.get("public_preset") is True)


def prepare_plan(api: TestClient, name: str) -> dict[str, Any]:
    created = api.post(
        "/api/v1/sessions",
        headers=headers(f"{name}-session"),
        json={
            "schema_version": "1.0",
            "source_channel": "demo_preset",
            "mode": "original_replication",
            "external_ai_consent": False,
            "user_constraints": {
                "solo_traveler": True,
                "tripod_available": False,
                "has_luggage": False,
                "notes": None,
            },
        },
    )
    assert created.status_code == 201
    session_id = created.json()["data"]["session_id"]
    analyzed = api.post(
        "/api/v1/references/analyze",
        headers=headers(f"{name}-reference"),
        json={
            "schema_version": "1.0",
            "session_id": session_id,
            "reference_asset": fixture_case()["reference_asset"],
        },
    )
    assert analyzed.status_code == 202
    planned = api.post(
        "/api/v1/agent/runs",
        headers=headers(f"{name}-plan"),
        json={
            "schema_version": "1.0",
            "session_id": session_id,
            "intent": "original_replication",
        },
    )
    assert planned.status_code == 202
    return api.get(f"/api/v1/sessions/{session_id}").json()["data"]


def create_handoff(
    api: TestClient, session_id: str, *, key_headers: dict[str, str] | None = None
) -> Any:
    return api.post(
        "/api/v1/handoffs",
        headers=key_headers or headers("create"),
        json={"schema_version": "1.0", "session_id": session_id},
    )


def test_handoff_is_safe_claimed_once_cached_and_completed() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    with TestClient(app) as api:
        session = prepare_plan(api, "closed-loop")
        create_headers = headers("create-replay")
        created = create_handoff(api, session["session_id"], key_headers=create_headers)
        replayed = create_handoff(api, session["session_id"], key_headers=create_headers)
        assert created.status_code == 201
        assert replayed.status_code == 200
        assert replayed.json()["data"] == created.json()["data"]

        creation = created.json()["data"]
        task = creation["handoff"]
        code = task["code"]
        assert set(code) <= set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        assert creation["qr_payload"].endswith(f"/handoff/{code}")
        assert "session_id" not in task
        assert "management_token" not in task
        handoff_session = api.get(f"/api/v1/sessions/{session['session_id']}")
        assert handoff_session.json()["data"]["state"] == "handoff_ready"

        public = api.get(f"/api/v1/handoffs/{code}")
        assert public.status_code == 200
        assert public.json()["data"] == task
        serialized_public = json.dumps(public.json(), sort_keys=True)
        assert session["session_id"] not in serialized_public
        assert session["shot_plan"]["plan_id"] not in serialized_public

        client_a = "ios-client-a-12345678"
        claimed = api.post(
            f"/api/v1/handoffs/{code}/claim",
            headers=headers("claim-a"),
            json={"schema_version": "1.0", "client_instance_id": client_a},
        )
        assert claimed.status_code == 200
        claim = claimed.json()["data"]
        assert claim["session"]["session_id"] == session["session_id"]
        assert claim["session"]["shot_plan"]["plan_id"] == session["shot_plan"]["plan_id"]
        assert claim["reference_access"] is None
        assert claim["handoff"]["status"] == "claimed"

        same_device = api.post(
            f"/api/v1/handoffs/{code}/claim",
            headers=headers("claim-a-recover"),
            json={"schema_version": "1.0", "client_instance_id": client_a},
        )
        assert same_device.status_code == 200
        assert same_device.json()["data"]["claim_token"] == claim["claim_token"]

        other_device = api.post(
            f"/api/v1/handoffs/{code}/claim",
            headers=headers("claim-b"),
            json={
                "schema_version": "1.0",
                "client_instance_id": "ios-client-b-87654321",
            },
        )
        assert other_device.status_code == 409
        assert other_device.json()["error"]["code"] == "HANDOFF_ALREADY_CLAIMED"

        invalid_complete = api.post(
            f"/api/v1/handoffs/{code}/complete",
            headers={**headers("bad-complete"), "X-Handoff-Claim-Token": "x" * 32},
            json={"schema_version": "1.0", "client_instance_id": client_a},
        )
        assert invalid_complete.status_code == 401
        assert invalid_complete.json()["error"]["code"] == "HANDOFF_INVALID_TOKEN"

        complete_headers = {
            **headers("complete"),
            "X-Handoff-Claim-Token": claim["claim_token"],
        }
        completed = api.post(
            f"/api/v1/handoffs/{code}/complete",
            headers=complete_headers,
            json={"schema_version": "1.0", "client_instance_id": client_a},
        )
        completed_replay = api.post(
            f"/api/v1/handoffs/{code}/complete",
            headers=complete_headers,
            json={"schema_version": "1.0", "client_instance_id": client_a},
        )
        assert completed.status_code == completed_replay.status_code == 200
        assert completed.json()["data"]["status"] == "completed"
        assert len(store.events) == 1

        revoke_completed = api.delete(
            f"/api/v1/handoffs/{code}",
            headers={
                **headers("revoke-completed"),
                "X-Handoff-Management-Token": creation["management_token"],
            },
        )
        assert revoke_completed.status_code == 409

        persisted = json.dumps(
            {
                "handoffs": store.handoffs,
                "idempotency": [record.data for record in store.idempotency.values()],
            }
        )
        assert creation["management_token"] not in persisted
        assert claim["claim_token"] not in persisted


def test_handoff_revoke_expiry_regeneration_and_session_delete() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    now = [datetime(2026, 7, 18, 8, 0, tzinfo=UTC)]
    app.state.handoff_service.clock = lambda: now[0]
    with TestClient(app) as api:
        session = prepare_plan(api, "lifecycle")
        session_id = session["session_id"]
        first = create_handoff(api, session_id).json()["data"]
        code = first["handoff"]["code"]

        invalid = api.delete(
            f"/api/v1/handoffs/{code}",
            headers={
                **headers("invalid-token"),
                "X-Handoff-Management-Token": "invalid" * 8,
            },
        )
        assert invalid.status_code == 401

        revoked = api.delete(
            f"/api/v1/handoffs/{code}",
            headers={
                **headers("revoke"),
                "X-Handoff-Management-Token": first["management_token"],
            },
        )
        assert revoked.status_code == 200
        assert revoked.json()["data"]["status"] == "revoked"
        restored_session = api.get(f"/api/v1/sessions/{session_id}")
        assert restored_session.json()["data"]["state"] == "shot_plan_ready"
        gone = api.post(
            f"/api/v1/handoffs/{code}/claim",
            headers=headers("claim-revoked"),
            json={"schema_version": "1.0", "client_instance_id": "client-revoked"},
        )
        assert gone.status_code == 410
        assert gone.json()["error"]["code"] == "HANDOFF_REVOKED"

        second = create_handoff(api, session_id).json()["data"]
        assert second["handoff"]["code"] != code
        now[0] += timedelta(seconds=601)
        expired = api.get(f"/api/v1/handoffs/{second['handoff']['code']}")
        assert expired.status_code == 410
        assert expired.json()["error"]["code"] == "HANDOFF_EXPIRED"
        restored_session = api.get(f"/api/v1/sessions/{session_id}")
        assert restored_session.json()["data"]["state"] == "shot_plan_ready"

        third = create_handoff(api, session_id).json()["data"]
        deleted = api.delete(f"/api/v1/sessions/{session_id}", headers=headers("delete"))
        assert deleted.status_code == 200
        assert api.get(f"/api/v1/handoffs/{third['handoff']['code']}").status_code == 404


def test_handoff_concurrent_claim_and_rate_limit_are_deterministic() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    with TestClient(app) as api:
        session = prepare_plan(api, "concurrent")
        created = create_handoff(api, session["session_id"]).json()["data"]
        code = created["handoff"]["code"]

        async def race() -> list[str]:
            async def attempt(index: int) -> str:
                try:
                    await app.state.handoff_service.claim(
                        code,
                        {
                            "schema_version": "1.0",
                            "client_instance_id": f"concurrent-client-{index:08d}",
                        },
                        f"race-key-{index}",
                        f"race-ip-{index}",
                    )
                    return "claimed"
                except DomainError as error:
                    return error.code

            return await asyncio.gather(*(attempt(index) for index in range(8)))

        outcomes = asyncio.run(race())
        assert outcomes.count("claimed") == 1
        assert outcomes.count("HANDOFF_ALREADY_CLAIMED") == 7

        limiter = app.state.handoff_service.rate_limiter
        asyncio.run(limiter.consume("test", "same-device", 1))
        try:
            asyncio.run(limiter.consume("test", "same-device", 1))
        except DomainError as error:
            assert error.code == "HANDOFF_RATE_LIMITED"
            assert error.status_code == 429
            assert error.retry_after is not None
        else:
            raise AssertionError("rate limiter did not reject the second request")


def test_redis_rate_limiter_fails_closed() -> None:
    class BrokenPipeline:
        async def __aenter__(self) -> BrokenPipeline:
            return self

        async def __aexit__(self, *_: object) -> None:
            return None

        def incr(self, _: str) -> None:
            return None

        def expire(self, _: str, __: int) -> None:
            return None

        async def execute(self) -> list[int]:
            raise ConnectionError("redis unavailable")

    class BrokenRedis:
        def pipeline(self, *, transaction: bool) -> BrokenPipeline:
            assert transaction is True
            return BrokenPipeline()

        async def aclose(self) -> None:
            return None

    limiter = RedisHandoffRateLimiter("redis://localhost:1")
    limiter._redis = BrokenRedis()  # type: ignore[assignment]
    try:
        asyncio.run(limiter.consume("claim", "device", 10))
    except DomainError as error:
        assert error.status_code == 503
        assert error.retry_after == 5
    else:
        raise AssertionError("Redis failure must not bypass claim protection")
