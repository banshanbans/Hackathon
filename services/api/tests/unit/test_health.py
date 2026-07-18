from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_returns_stable_safe_response() -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "schema_version": "1.0",
        "request_id": response.headers["X-Request-ID"],
        "status": "ok",
        "service": "soloshot-api",
        "version": "0.1.0",
    }
    serialized = response.text.lower()
    assert "secret" not in serialized
    assert "token" not in serialized


def test_health_preserves_safe_request_id() -> None:
    response = client.get("/health", headers={"X-Request-ID": "w0-contract-check"})

    assert response.status_code == 200
    assert response.headers["X-Request-ID"] == "w0-contract-check"
    assert response.json()["request_id"] == "w0-contract-check"


def test_health_replaces_oversized_request_id() -> None:
    response = client.get("/health", headers={"X-Request-ID": "x" * 129})

    assert response.status_code == 200
    assert response.headers["X-Request-ID"] != "x" * 129


def test_h5_origin_can_preflight_mock_api_requests() -> None:
    response = client.options(
        "/api/v1/sessions",
        headers={
            "Origin": "http://localhost:5173",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type,idempotency-key",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://localhost:5173"
    assert "Idempotency-Key" in response.headers["access-control-allow-headers"]
