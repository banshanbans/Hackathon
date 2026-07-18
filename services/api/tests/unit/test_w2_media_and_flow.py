from __future__ import annotations

import asyncio
import hashlib
import json
from datetime import UTC, datetime, timedelta
from io import BytesIO
from pathlib import Path
from typing import Any
from uuid import uuid4

from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.main import create_app
from app.media.storage import MemoryObjectStorage
from app.persistence.store import MemoryStateStore

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
MANIFEST_PATH = REPOSITORY_ROOT / "packages/evals/test-image-v1/manifest.json"


def key(name: str) -> dict[str, str]:
    return {"Idempotency-Key": f"w2-test-{name}-{uuid4()}"}


def jpeg_bytes(width: int = 12, height: int = 8) -> bytes:
    output = BytesIO()
    Image.new("RGB", (width, height), color=(246, 108, 52)).save(output, format="JPEG")
    return output.getvalue()


def create_session(api: TestClient, name: str, *, consent: bool = True) -> dict[str, Any]:
    response = api.post(
        "/api/v1/sessions",
        headers=key(name),
        json={
            "schema_version": "1.0",
            "source_channel": "h5_direct",
            "mode": "original_replication",
            "external_ai_consent": consent,
            "user_constraints": {
                "solo_traveler": True,
                "tripod_available": False,
                "has_luggage": False,
                "notes": None,
            },
        },
    )
    assert response.status_code == 201
    return response.json()["data"]


def put_memory_upload(app: Any, ticket: dict[str, Any], content: bytes) -> None:
    storage = app.state.object_storage
    assert isinstance(storage, MemoryObjectStorage)
    prefix = "memory://upload/"
    upload_url = ticket["upload_url"]
    assert upload_url.startswith(prefix)
    storage.put_for_test(upload_url.removeprefix(prefix), content)


def request_upload(
    api: TestClient,
    session_id: str,
    content: bytes,
    *,
    purpose: str = "reference",
    content_type: str = "image/jpeg",
    digest: str | None = None,
) -> dict[str, Any]:
    response = api.post(
        "/api/v1/media/uploads",
        headers=key(f"upload-{purpose}"),
        json={
            "schema_version": "1.0",
            "session_id": session_id,
            "purpose": purpose,
            "content_type": content_type,
            "byte_size": len(content),
            "sha256": digest or hashlib.sha256(content).hexdigest(),
        },
    )
    assert response.status_code == 201
    return response.json()["data"]


def test_media_lifecycle_validates_integrity_ownership_cleanup_and_session_delete() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    content = jpeg_bytes()
    with TestClient(app) as api:
        owner = create_session(api, "owner")
        other = create_session(api, "other")
        ticket = request_upload(api, owner["session_id"], content)
        put_memory_upload(app, ticket, content)
        media_id = ticket["asset"]["media_asset_id"]

        completed = api.post(
            f"/api/v1/media/uploads/{media_id}/complete",
            headers=key("complete"),
            json={"schema_version": "1.0", "session_id": owner["session_id"]},
        )
        assert completed.status_code == 200
        assert completed.json()["data"]["status"] == "ready"
        assert completed.json()["data"]["width"] == 12

        access = api.get(
            f"/api/v1/media/{media_id}/access",
            params={"session_id": owner["session_id"]},
        )
        assert access.status_code == 200
        assert access.json()["data"]["download_url"].startswith("memory://download/")
        denied = api.get(
            f"/api/v1/media/{media_id}/access",
            params={"session_id": other["session_id"]},
        )
        assert denied.status_code == 404
        assert denied.json()["error"]["code"] == "MEDIA_ACCESS_DENIED"

        record = store.media[media_id]
        record.asset["expires_at"] = (datetime.now(UTC) - timedelta(seconds=1)).isoformat()
        assert asyncio.run(app.state.media_service.cleanup_expired()) == 1
        assert media_id not in store.media

        replacement = request_upload(api, owner["session_id"], content, purpose="capture")
        put_memory_upload(app, replacement, content)
        replacement_id = replacement["asset"]["media_asset_id"]
        deleted = api.delete(
            f"/api/v1/sessions/{owner['session_id']}",
            headers=key("delete-owner"),
        )
        assert deleted.status_code == 200
        assert replacement_id not in store.media
        assert app.state.object_storage.objects == {}


def test_media_rejects_wrong_hash_magic_type_and_oversize_declaration() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    content = jpeg_bytes()
    with TestClient(app) as api:
        session = create_session(api, "integrity")
        session_id = session["session_id"]

        wrong_hash = request_upload(api, session_id, content, digest="0" * 64)
        put_memory_upload(app, wrong_hash, content)
        failed_hash = api.post(
            f"/api/v1/media/uploads/{wrong_hash['asset']['media_asset_id']}/complete",
            headers=key("wrong-hash"),
            json={"schema_version": "1.0", "session_id": session_id},
        )
        assert failed_hash.status_code == 422
        assert failed_hash.json()["error"]["code"] == "MEDIA_INTEGRITY_FAILED"

        wrong_type = request_upload(api, session_id, content, content_type="image/png")
        put_memory_upload(app, wrong_type, content)
        failed_type = api.post(
            f"/api/v1/media/uploads/{wrong_type['asset']['media_asset_id']}/complete",
            headers=key("wrong-type"),
            json={"schema_version": "1.0", "session_id": session_id},
        )
        assert failed_type.status_code == 422
        assert failed_type.json()["error"]["code"] == "UNSUPPORTED_MEDIA"

        oversized_dimensions = jpeg_bytes(2049, 1)
        too_wide = request_upload(api, session_id, oversized_dimensions)
        put_memory_upload(app, too_wide, oversized_dimensions)
        failed_dimensions = api.post(
            f"/api/v1/media/uploads/{too_wide['asset']['media_asset_id']}/complete",
            headers=key("oversized-dimensions"),
            json={"schema_version": "1.0", "session_id": session_id},
        )
        assert failed_dimensions.status_code == 422
        assert failed_dimensions.json()["error"]["code"] == "UNSUPPORTED_MEDIA"

        oversized = api.post(
            "/api/v1/media/uploads",
            headers=key("oversized"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "purpose": "capture",
                "content_type": "image/jpeg",
                "byte_size": 8_000_001,
                "sha256": "0" * 64,
            },
        )
        assert oversized.status_code == 422
        assert oversized.json()["error"]["code"] == "VALIDATION_FAILED"


def test_live_media_requires_consent_and_unconfigured_provider_never_uses_fixture() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    content = jpeg_bytes()
    with TestClient(app) as api:
        no_consent = create_session(api, "no-consent", consent=False)
        refused = api.post(
            "/api/v1/media/uploads",
            headers=key("consent-required"),
            json={
                "schema_version": "1.0",
                "session_id": no_consent["session_id"],
                "purpose": "reference",
                "content_type": "image/jpeg",
                "byte_size": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            },
        )
        assert refused.status_code == 409
        assert refused.json()["error"]["code"] == "CONSENT_REQUIRED"

        live = create_session(api, "live")
        ticket = request_upload(api, live["session_id"], content)
        put_memory_upload(app, ticket, content)
        media_id = ticket["asset"]["media_asset_id"]
        assert (
            api.post(
                f"/api/v1/media/uploads/{media_id}/complete",
                headers=key("live-complete"),
                json={"schema_version": "1.0", "session_id": live["session_id"]},
            ).status_code
            == 200
        )
        analyzed = api.post(
            "/api/v1/references/analyze",
            headers=key("live-analyze"),
            json={
                "schema_version": "1.0",
                "session_id": live["session_id"],
                "reference_asset": {
                    "schema_version": "1.0",
                    "reference_id": "ref_live_unconfigured",
                    "media_asset_id": media_id,
                    "media_type": "image",
                    "source_type": "upload",
                    "width": 12,
                    "height": 8,
                    "selected_box": {"x": 0.2, "y": 0.1, "width": 0.5, "height": 0.8},
                    "attribution": {"source_label": "user selected local media"},
                },
            },
        )
        assert analyzed.status_code == 503
        assert analyzed.json()["error"]["code"] == "PROVIDER_UNAVAILABLE"
        assert "X-SoloShot-Execution-Mode" not in analyzed.headers


def public_fixture_case() -> dict[str, Any]:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    return next(item for item in manifest["cases"] if item.get("public_preset") is True)


def test_fixture_two_round_history_is_ordered_idempotent_and_safety_blocks_plan() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    case = public_fixture_case()
    with TestClient(app) as api:
        session = create_session(api, "fixture", consent=False)
        session_id = session["session_id"]
        analyzed = api.post(
            "/api/v1/references/analyze",
            headers=key("fixture-analysis"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "reference_asset": case["reference_asset"],
            },
        )
        assert analyzed.status_code == 202
        assert analyzed.headers["X-SoloShot-Execution-Mode"] == "fixture"
        planned = api.post(
            "/api/v1/agent/runs",
            headers=key("fixture-plan"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "intent": "original_replication",
            },
        )
        assert [item["name"] for item in planned.json()["data"]["selected_skills"]] == [
            "shooting_plan"
        ]

        evaluation_key = key("evaluation-one")
        for round_index in (1, 2):
            captured = api.post(
                "/api/v1/captures",
                headers=key(f"capture-{round_index}"),
                json={
                    "schema_version": "1.0",
                    "session_id": session_id,
                    "round_index": round_index,
                    "media_asset_id": f"media_fixture_{case['case_id']}_round_{round_index}",
                },
            )
            evaluation_headers = evaluation_key if round_index == 1 else key("evaluation-two")
            evaluated = api.post(
                "/api/v1/evaluations",
                headers=evaluation_headers,
                json={
                    "schema_version": "1.0",
                    "session_id": session_id,
                    "capture_id": captured.json()["data"]["capture_id"],
                },
            )
            assert evaluated.status_code == 202
            if round_index == 1:
                replayed = api.post(
                    "/api/v1/evaluations",
                    headers=evaluation_headers,
                    json={
                        "schema_version": "1.0",
                        "session_id": session_id,
                        "capture_id": captured.json()["data"]["capture_id"],
                    },
                )
                assert replayed.json()["data"] == evaluated.json()["data"]
                assert replayed.headers["X-SoloShot-Execution-Mode"] == "cache"

        final = api.get(f"/api/v1/sessions/{session_id}").json()["data"]
        assert final["state"] == "completed"
        assert [item["capture_id"] for item in final["evaluations"]] == [
            item["capture_id"] for item in final["capture_rounds"]
        ]
        assert len(final["evaluations"]) == 2

        blocked = create_session(api, "blocked", consent=False)
        blocked_id = blocked["session_id"]
        assert (
            api.post(
                "/api/v1/references/analyze",
                headers=key("blocked-analysis"),
                json={
                    "schema_version": "1.0",
                    "session_id": blocked_id,
                    "reference_asset": case["reference_asset"],
                },
            ).status_code
            == 202
        )
        store.analyses[blocked_id]["safety_status"] = "block"
        store.analyses[blocked_id]["safety_warnings"] = ["危险地点"]
        rejected = api.post(
            "/api/v1/agent/runs",
            headers=key("blocked-plan"),
            json={
                "schema_version": "1.0",
                "session_id": blocked_id,
                "intent": "original_replication",
            },
        )
        assert rejected.status_code == 422
        assert rejected.json()["error"]["code"] == "UNSAFE_INSTRUCTION"


def test_event_batch_deduplicates_and_rejects_sensitive_fields() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    with TestClient(app) as api:
        session = create_session(api, "events")
        event = {
            "schema_version": "1.0",
            "event_id": str(uuid4()),
            "event_name": "page_view",
            "session_id": session["session_id"],
            "source_channel": "h5_direct",
            "client": "h5",
            "timestamp": datetime.now(UTC).isoformat(),
            "properties": {"route": "/reference", "mode": "original_replication"},
        }
        first = api.post(
            "/api/v1/events/batch",
            headers=key("events-first"),
            json={"schema_version": "1.0", "events": [event]},
        )
        second = api.post(
            "/api/v1/events/batch",
            headers=key("events-second"),
            json={"schema_version": "1.0", "events": [event]},
        )
        assert first.json()["data"] == {
            "schema_version": "1.0",
            "accepted_count": 1,
            "duplicate_count": 0,
        }
        assert second.json()["data"]["duplicate_count"] == 1

        unsafe = {**event, "event_id": str(uuid4()), "properties": {"filename": "secret.jpg"}}
        rejected = api.post(
            "/api/v1/events/batch",
            headers=key("events-privacy"),
            json={"schema_version": "1.0", "events": [unsafe]},
        )
        assert rejected.status_code == 422
        assert rejected.json()["error"]["code"] == "VALIDATION_FAILED"
