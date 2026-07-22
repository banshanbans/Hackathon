from __future__ import annotations

import hashlib
import json
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


def key(name: str) -> dict[str, str]:
    return {"Idempotency-Key": f"w5-{name}-{uuid4()}"}


def preset() -> dict[str, Any]:
    manifest = json.loads(
        (REPOSITORY_ROOT / "packages/evals/test-image-v1/manifest.json").read_text()
    )
    return next(item for item in manifest["cases"] if item.get("public_preset"))


def jpeg() -> bytes:
    output = BytesIO()
    Image.new("RGB", (72, 128), color=(238, 108, 52)).save(output, format="JPEG")
    return output.getvalue()


def prepare_h5_session(api: TestClient) -> str:
    created = api.post(
        "/api/v1/sessions",
        headers=key("session"),
        json={
            "schema_version": "1.0",
            "source_channel": "demo_preset",
            "mode": "original_replication",
            "external_ai_consent": False,
            "user_constraints": {
                "solo_traveler": True,
                "tripod_available": True,
                "has_luggage": False,
                "notes": None,
            },
        },
    ).json()["data"]
    session_id = created["session_id"]
    assert api.post(
        "/api/v1/references/analyze",
        headers=key("reference"),
        json={
            "schema_version": "1.0",
            "session_id": session_id,
            "reference_asset": preset()["reference_asset"],
        },
    ).status_code == 202
    assert api.post(
        "/api/v1/agent/runs",
        headers=key("plan"),
        json={
            "schema_version": "1.0",
            "session_id": session_id,
            "intent": "original_replication",
        },
    ).status_code == 202
    return session_id


def prepare_handoff(api: TestClient) -> tuple[str, str, str]:
    session_id = prepare_h5_session(api)
    handoff = api.post(
        "/api/v1/handoffs",
        headers=key("handoff"),
        json={"schema_version": "1.0", "session_id": session_id},
    ).json()["data"]
    code = handoff["handoff"]["code"]
    client_id = "ios-w5-test-client"
    claim = api.post(
        f"/api/v1/handoffs/{code}/claim",
        headers=key("claim"),
        json={"schema_version": "1.0", "client_instance_id": client_id},
    ).json()["data"]
    return session_id, code, claim["claim_token"]


def complete_handoff(api: TestClient, code: str, token: str) -> None:
    response = api.post(
        f"/api/v1/handoffs/{code}/complete",
        headers={**key("complete"), "X-Handoff-Claim-Token": token},
        json={"schema_version": "1.0", "client_instance_id": "ios-w5-test-client"},
    )
    assert response.status_code == 200


def test_ios_capture_requires_completed_handoff_token_and_records_fixture_mode() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    image = jpeg()
    with TestClient(app) as api:
        session_id, code, token = prepare_handoff(api)
        locked = api.post(
            "/api/v1/captures",
            headers=key("locked"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "round_index": 1,
                "media_asset_id": "media_fixture_locked",
            },
        )
        assert locked.status_code == 409

        complete_handoff(api, code, token)
        missing_token = api.post(
            "/api/v1/media/uploads",
            headers=key("missing-token"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "purpose": "capture",
                "content_type": "image/jpeg",
                "byte_size": len(image),
                "sha256": hashlib.sha256(image).hexdigest(),
            },
        )
        assert missing_token.status_code == 401
        assert missing_token.json()["error"]["code"] == "HANDOFF_INVALID_TOKEN"

        consent = api.post(
            f"/api/v1/sessions/{session_id}/capture-consent",
            headers={**key("consent"), "X-Handoff-Claim-Token": token},
            json={
                "schema_version": "1.0",
                "capture_upload_consent": True,
                "external_ai_consent": False,
            },
        )
        assert consent.status_code == 200
        assert consent.json()["data"]["external_ai_consent_at"] is None

        ticket = api.post(
            "/api/v1/media/uploads",
            headers={**key("upload"), "X-Handoff-Claim-Token": token},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "purpose": "capture",
                "content_type": "image/jpeg",
                "byte_size": len(image),
                "sha256": hashlib.sha256(image).hexdigest(),
            },
        )
        assert ticket.status_code == 201
        ticket_data = ticket.json()["data"]
        storage = app.state.object_storage
        assert isinstance(storage, MemoryObjectStorage)
        storage.put_for_test(
            ticket_data["upload_url"].removeprefix("memory://upload/"), image
        )
        media_id = ticket_data["asset"]["media_asset_id"]
        assert api.post(
            f"/api/v1/media/uploads/{media_id}/complete",
            headers={**key("verify"), "X-Handoff-Claim-Token": token},
            json={"schema_version": "1.0", "session_id": session_id},
        ).status_code == 200

        captured = api.post(
            "/api/v1/captures",
            headers={**key("capture"), "X-Handoff-Claim-Token": token},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "round_index": 1,
                "media_asset_id": media_id,
                "capture_method": "photo",
                "frame_selection": {
                    "frame_id": "frame_w5_selected",
                    "timestamp_ms": None,
                    "selection_source": "local_recommended",
                },
            },
        )
        assert captured.status_code == 201
        capture = captured.json()["data"]
        assert capture["source_client"] == "ios"
        assert capture["selected_frame_id"] == "frame_w5_selected"

        evaluated = api.post(
            "/api/v1/evaluations",
            headers={**key("evaluate"), "X-Handoff-Claim-Token": token},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "capture_id": capture["capture_id"],
            },
        )
        assert evaluated.status_code == 202
        assert evaluated.json()["data"]["execution_mode"] == "fixture"
        after_round_one = api.get(f"/api/v1/sessions/{session_id}").json()["data"]
        assert after_round_one["state"] == "coaching"
        assert after_round_one["capture_upload_consent_at"] is not None

        round_two = api.post(
            "/api/v1/captures",
            headers={**key("capture-2"), "X-Handoff-Claim-Token": token},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "round_index": 2,
                "media_asset_id": "media_fixture_w5_round_2",
                "capture_method": "photo_fallback",
                "frame_selection": {
                    "frame_id": "frame_w5_round_2",
                    "timestamp_ms": 0,
                    "selection_source": "user_selected",
                },
            },
        )
        assert round_two.status_code == 201
        duplicate_round = api.post(
            "/api/v1/captures",
            headers={**key("capture-2-duplicate"), "X-Handoff-Claim-Token": token},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "round_index": 2,
                "media_asset_id": "media_fixture_w5_round_2",
                "capture_method": "photo_fallback",
                "frame_selection": {
                    "frame_id": "frame_w5_round_2_duplicate",
                    "timestamp_ms": 0,
                    "selection_source": "user_selected",
                },
            },
        )
        assert duplicate_round.status_code == 409
        evaluated_round_two = api.post(
            "/api/v1/evaluations",
            headers={**key("evaluate-2"), "X-Handoff-Claim-Token": token},
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "capture_id": round_two.json()["data"]["capture_id"],
            },
        )
        assert evaluated_round_two.status_code == 202
        assert evaluated_round_two.json()["data"]["execution_mode"] == "fixture"

        final = api.get(f"/api/v1/sessions/{session_id}").json()["data"]
        assert final["state"] == "completed"
        assert len(final["evaluations"]) == 2
        assert final["capture_upload_consent_at"] is not None
        trusted_events = [
            event
            for event in store.events.values()
            if event["event_name"] in {"result_upload", "result_evaluated"}
        ]
        assert [event["event_name"] for event in trusted_events] == [
            "result_upload",
            "result_evaluated",
            "result_upload",
            "result_evaluated",
        ]
        assert all(event["client"] == "ios" for event in trusted_events)
        serialized_events = json.dumps(trusted_events)
        assert "claim-token" not in serialized_events
        assert "media_asset_id" not in serialized_events
        assert "frame_id" not in serialized_events


def test_h5_can_record_capture_consent_before_browser_live_capture() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    with TestClient(app) as api:
        session_id = prepare_h5_session(api)
        response = api.post(
            f"/api/v1/sessions/{session_id}/capture-consent",
            headers=key("h5-browser-consent"),
            json={
                "schema_version": "1.0",
                "capture_upload_consent": True,
                "external_ai_consent": False,
            },
        )
        assert response.status_code == 200
        assert response.json()["data"]["capture_upload_consent_at"] is not None
        assert response.json()["data"]["external_ai_consent_at"] is None

        image = jpeg()
        ticket = api.post(
            "/api/v1/media/uploads",
            headers=key("h5-browser-upload"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "purpose": "capture",
                "content_type": "image/jpeg",
                "byte_size": len(image),
                "sha256": hashlib.sha256(image).hexdigest(),
            },
        )
        assert ticket.status_code == 201
        ticket_data = ticket.json()["data"]
        storage = app.state.object_storage
        assert isinstance(storage, MemoryObjectStorage)
        storage.put_for_test(
            ticket_data["upload_url"].removeprefix("memory://upload/"), image
        )
        media_id = ticket_data["asset"]["media_asset_id"]
        assert api.post(
            f"/api/v1/media/uploads/{media_id}/complete",
            headers=key("h5-browser-complete"),
            json={"schema_version": "1.0", "session_id": session_id},
        ).status_code == 200

        captured = api.post(
            "/api/v1/captures",
            headers=key("h5-browser-capture"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "round_index": 1,
                "media_asset_id": media_id,
                "capture_method": "photo",
                "frame_selection": {
                    "frame_id": "frame_h5_browser_recommended",
                    "timestamp_ms": None,
                    "selection_source": "local_recommended",
                },
            },
        )
        assert captured.status_code == 201
        assert captured.json()["data"]["source_client"] == "h5"
        assert captured.json()["data"]["selected_frame_id"] == "frame_h5_browser_recommended"
        evaluated = api.post(
            "/api/v1/evaluations",
            headers=key("h5-browser-evaluation"),
            json={
                "schema_version": "1.0",
                "session_id": session_id,
                "capture_id": captured.json()["data"]["capture_id"],
            },
        )
        assert evaluated.status_code == 202
        assert evaluated.headers["X-SoloShot-Execution-Mode"] == "fixture"


def test_capture_consent_rejects_tampered_token() -> None:
    store = MemoryStateStore()
    app = create_app(store, Settings(model_provider="hybrid"))
    with TestClient(app) as api:
        session_id, code, token = prepare_handoff(api)
        complete_handoff(api, code, token)
        response = api.post(
            f"/api/v1/sessions/{session_id}/capture-consent",
            headers={**key("bad-consent"), "X-Handoff-Claim-Token": "x" * 32},
            json={
                "schema_version": "1.0",
                "capture_upload_consent": True,
                "external_ai_consent": False,
            },
        )
        assert response.status_code == 401
        assert response.json()["error"]["code"] == "HANDOFF_INVALID_TOKEN"
