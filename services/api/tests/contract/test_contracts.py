from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

import pytest
import yaml
from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import ValidationError
from openapi_spec_validator import validate_url
from referencing import Registry, Resource

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
CONTRACT_ROOT = REPOSITORY_ROOT / "packages" / "contracts"
SCHEMA_ROOT = CONTRACT_ROOT / "schemas"
OPENAPI_PATH = CONTRACT_ROOT / "openapi.yaml"
SESSION_FIXTURE_PATH = CONTRACT_ROOT / "fixtures" / "session.v1.json"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_openapi() -> dict[str, Any]:
    return yaml.safe_load(OPENAPI_PATH.read_text(encoding="utf-8"))


def schema_registry() -> Registry[Any]:
    resources = [
        (path.as_uri(), Resource.from_contents(load_json(path)))
        for path in SCHEMA_ROOT.glob("*.schema.json")
    ]
    return Registry().with_resources(resources)


def session_validator() -> Draft202012Validator:
    session_schema_path = SCHEMA_ROOT / "session.schema.json"
    session_schema = load_json(session_schema_path)
    session_schema["$id"] = session_schema_path.as_uri()
    return Draft202012Validator(
        session_schema,
        registry=schema_registry(),
        format_checker=FormatChecker(),
    )


def iter_external_references(value: Any) -> list[str]:
    references: list[str] = []
    if isinstance(value, dict):
        for key, nested in value.items():
            if key == "$ref" and isinstance(nested, str) and not nested.startswith("#"):
                references.append(nested)
            else:
                references.extend(iter_external_references(nested))
    elif isinstance(value, list):
        for nested in value:
            references.extend(iter_external_references(nested))
    return references


def test_all_json_schemas_are_valid_draft_2020_12() -> None:
    schema_paths = sorted(SCHEMA_ROOT.glob("*.schema.json"))
    assert schema_paths

    for path in schema_paths:
        Draft202012Validator.check_schema(load_json(path))


def test_openapi_document_is_valid_and_all_external_files_exist() -> None:
    document = load_openapi()
    validate_url(OPENAPI_PATH.as_uri())

    documents: list[tuple[Path, dict[str, Any]]] = [(OPENAPI_PATH, document)]
    documents.extend((path, load_json(path)) for path in SCHEMA_ROOT.glob("*.schema.json"))
    for source_path, source in documents:
        for reference in iter_external_references(source):
            path_part = reference.split("#", maxsplit=1)[0]
            if path_part.startswith("https://"):
                continue
            target = (source_path.parent / path_part).resolve()
            assert target.is_file(), f"{source_path} references missing file {target}"


def test_openapi_contains_the_accepted_w0_contract_surface() -> None:
    paths = set(load_openapi()["paths"])
    expected_paths = {
        "/health",
        "/api/v1/sessions",
        "/api/v1/sessions/{session_id}",
        "/api/v1/references/analyze",
        "/api/v1/references/adapt",
        "/api/v1/references/validate-box",
        "/api/v1/references/{reference_id}",
        "/api/v1/agent/runs",
        "/api/v1/agent/runs/{run_id}/continue",
        "/api/v1/agent/runs/{run_id}",
        "/api/v1/agent/runs/{run_id}/trace",
        "/api/v1/skills/{skill_name}/invoke",
        "/api/v1/captures",
        "/api/v1/captures/{capture_id}/select-frame",
        "/api/v1/captures/{capture_id}",
        "/api/v1/evaluations",
        "/api/v1/handoffs",
        "/api/v1/handoffs/{code}",
        "/api/v1/handoffs/{code}/claim",
        "/api/v1/handoffs/{code}/complete",
        "/api/v1/posts/render",
        "/api/v1/posts/{post_id}",
        "/api/v1/posts/{post_id}/publish-preview",
        "/api/v1/shares/{share_id}",
        "/api/v1/events/batch",
        "/api/v1/internal/metrics/funnel",
        "/api/v1/internal/metrics/costs",
    }
    assert paths == expected_paths


def test_every_write_operation_requires_an_idempotency_key() -> None:
    document = load_openapi()
    for path, path_item in document["paths"].items():
        for method in ("post", "put", "patch", "delete"):
            operation = path_item.get(method)
            if operation is None:
                continue
            parameters = [*path_item.get("parameters", []), *operation.get("parameters", [])]
            assert {parameter.get("$ref") for parameter in parameters} >= {
                "#/components/parameters/IdempotencyKey"
            }, f"{method.upper()} {path} does not require Idempotency-Key"


def test_every_success_response_declares_request_id_header() -> None:
    document = load_openapi()
    responses = document["components"]["responses"]
    for path, path_item in document["paths"].items():
        for method, operation in path_item.items():
            if method not in {"get", "post", "put", "patch", "delete"}:
                continue
            for status, response in operation["responses"].items():
                if not str(status).startswith("2"):
                    continue
                if "$ref" in response:
                    name = response["$ref"].rsplit("/", maxsplit=1)[-1]
                    response = responses[name]
                assert response["headers"]["X-Request-ID"] == {
                    "$ref": "#/components/headers/RequestId"
                }, f"{method.upper()} {path} {status} is missing X-Request-ID"


def test_canonical_session_fixture_is_valid() -> None:
    session_validator().validate(load_json(SESSION_FIXTURE_PATH))


@pytest.mark.parametrize(
    ("mutation", "expected_fragment"),
    [
        (("schema_version", "2.0"), "schema_version"),
        (("shot_plan.target_layout.center_x", 1.01), "center_x"),
        (("shot_plan.target_layout.body_direction", "diagonal"), "body_direction"),
    ],
)
def test_invalid_fixture_values_are_rejected(
    mutation: tuple[str, object],
    expected_fragment: str,
) -> None:
    fixture = copy.deepcopy(load_json(SESSION_FIXTURE_PATH))
    dotted_path, value = mutation
    target: dict[str, Any] = fixture
    parts = dotted_path.split(".")
    for part in parts[:-1]:
        target = target[part]
    target[parts[-1]] = value

    with pytest.raises(ValidationError) as error:
        session_validator().validate(fixture)
    assert expected_fragment in str(error.value)


def test_fixture_contains_no_credentials_or_signed_urls() -> None:
    serialized = SESSION_FIXTURE_PATH.read_text(encoding="utf-8").lower()
    forbidden_fragments = ("api_key", "access_token", "signed_url", "secret_key")

    assert not any(fragment in serialized for fragment in forbidden_fragments)
