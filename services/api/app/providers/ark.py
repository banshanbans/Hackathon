from __future__ import annotations

import base64
import json
import logging
from collections.abc import Awaitable, Callable
from dataclasses import replace
from pathlib import Path
from typing import Any

import httpx
from pydantic import BaseModel

from app.domain.errors import DomainError
from app.domain.models import JsonObject, PostJob, ReferenceAnalysis, ResultEvaluation, ShotPlan
from app.providers.base import ProviderResult, StructuredModelProvider
from app.providers.mock import FixtureProvider

logger = logging.getLogger("soloshot.providers.ark")
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
MediaLoader = Callable[[str], Awaitable[tuple[str, bytes]]]

OUTPUT_MODELS: dict[str, type[BaseModel]] = {
    "reference_understanding": ReferenceAnalysis,
    "scene_adaptation": ReferenceAnalysis,
    "shooting_plan": ShotPlan,
    "result_evaluation": ResultEvaluation,
    "content_composer": PostJob,
}


class VolcengineArkProvider:
    name = "volcengine-ark"
    execution_mode = "live"

    def __init__(
        self,
        *,
        api_key: str,
        model_id: str,
        base_url: str,
        timeout_seconds: float,
        media_loader: MediaLoader,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self.api_key = api_key
        self.model_id = model_id
        self.base_url = base_url.rstrip("/")
        self.media_loader = media_loader
        self._owns_client = client is None
        self.client = client or httpx.AsyncClient(timeout=timeout_seconds)

    async def aclose(self) -> None:
        if self._owns_client:
            await self.client.aclose()

    async def invoke(
        self,
        skill_name: str,
        input_data: JsonObject,
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        if not self.api_key or not self.model_id:
            raise DomainError(
                "PROVIDER_UNAVAILABLE",
                "Volcengine Ark requires ARK_API_KEY and ARK_MODEL_ID",
                status_code=503,
                recoverable=True,
            )
        output_model = OUTPUT_MODELS.get(skill_name)
        if output_model is None:
            raise DomainError(
                "SKILL_NOT_FOUND", f"Ark Skill {skill_name} is unavailable", status_code=404
            )
        prompt_version = "1.1.0" if skill_name == "result_evaluation" else "1.0.0"
        prompt_path = (
            REPOSITORY_ROOT
            / "packages"
            / "prompts"
            / skill_name
            / prompt_version
            / "system.md"
        )
        if not prompt_path.exists():
            raise DomainError(
                "SKILL_NOT_FOUND",
                f"Prompt bundle for {skill_name}@1.0.0 is unavailable",
                status_code=500,
            )
        content: list[JsonObject] = []
        for media_asset_id in self._media_ids(input_data):
            content_type, media_bytes = await self.media_loader(media_asset_id)
            encoded = base64.b64encode(media_bytes).decode("ascii")
            content.append(
                {
                    "type": "input_image",
                    "image_url": f"data:{content_type};base64,{encoded}",
                    "detail": "high",
                }
            )
        instruction = {
            "skill": skill_name,
            "input": input_data,
            "repair_error": repair_error,
            "response_rule": "Return only one JSON object matching the requested schema.",
        }
        content.append(
            {
                "type": "input_text",
                "text": json.dumps(instruction, ensure_ascii=False, separators=(",", ":")),
            }
        )
        payload: JsonObject = {
            "model": self.model_id,
            "store": False,
            "instructions": prompt_path.read_text(encoding="utf-8"),
            "input": [{"role": "user", "content": content}],
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": skill_name,
                    "schema": output_model.model_json_schema(),
                    "strict": True,
                }
            },
        }
        warnings: list[str] = ["COST_ESTIMATE_UNAVAILABLE"]
        response = await self._post(payload)
        if response.status_code == 400 and self._structured_output_unsupported(response):
            warnings.append("ARK_JSON_SCHEMA_UNAVAILABLE")
            payload.pop("text", None)
            response = await self._post(payload)
        self._raise_for_status(response)
        output = self._parse_output(response.json())
        confidence = output.get("confidence", 0.5)
        return ProviderResult(
            output=output,
            confidence=float(confidence) if isinstance(confidence, int | float) else 0.5,
            model=self.model_id,
            estimated_cost_usd=0.0,
            warnings=warnings,
            execution_mode="live",
            provider_name=self.name,
        )

    async def _post(self, payload: JsonObject) -> httpx.Response:
        try:
            return await self.client.post(
                f"{self.base_url}/responses",
                headers={"Authorization": f"Bearer {self.api_key}"},
                json=payload,
            )
        except httpx.TimeoutException as error:
            raise DomainError(
                "MODEL_TIMEOUT",
                "Volcengine Ark request timed out",
                status_code=503,
                recoverable=True,
            ) from error
        except httpx.HTTPError as error:
            raise DomainError(
                "PROVIDER_UNAVAILABLE",
                "Volcengine Ark could not be reached",
                status_code=503,
                recoverable=True,
            ) from error

    @staticmethod
    def _structured_output_unsupported(response: httpx.Response) -> bool:
        detail = response.text.lower()
        return any(token in detail for token in ("json_schema", "text.format", "response_format"))

    @staticmethod
    def _upstream_error_code(response: httpx.Response) -> str | None:
        try:
            payload = response.json()
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None
        if not isinstance(payload, dict):
            return None
        error = payload.get("error")
        code = error.get("code") if isinstance(error, dict) else payload.get("code")
        return code if isinstance(code, str) else None

    @classmethod
    def _raise_for_status(cls, response: httpx.Response) -> None:
        if response.is_success:
            return
        upstream_code = cls._upstream_error_code(response)
        request_id = next(
            (
                response.headers[name]
                for name in ("x-request-id", "x-tt-logid", "x-log-id")
                if name in response.headers
            ),
            None,
        )
        logger.warning(
            "ark_request_failed status=%d upstream_code=%s request_id=%s",
            response.status_code,
            upstream_code or "unknown",
            request_id or "unknown",
        )
        diagnostic = " ".join(
            value for value in (upstream_code, response.text[:512]) if value
        ).lower()
        configuration_error = response.status_code == 404 or any(
            token in diagnostic
            for token in (
                "invalidendpointormodel",
                "model_not_found",
                "model not found",
                "invalid model",
                "model does not exist",
                "model id",
            )
        )
        if (
            configuration_error
            or response.status_code in {401, 403, 429}
            or response.status_code >= 500
        ):
            raise DomainError(
                "PROVIDER_UNAVAILABLE",
                "Volcengine Ark rejected or could not process the request",
                status_code=503,
                recoverable=True,
            )
        raise DomainError(
            "PROVIDER_REJECTED",
            "Volcengine Ark rejected the media or structured request",
            status_code=422,
            recoverable=True,
        )

    @staticmethod
    def _parse_output(payload: Any) -> JsonObject:
        if isinstance(payload, dict) and isinstance(payload.get("output_text"), str):
            return VolcengineArkProvider._decode_json(payload["output_text"])
        if isinstance(payload, dict) and isinstance(payload.get("output"), list):
            for item in payload["output"]:
                if not isinstance(item, dict) or not isinstance(item.get("content"), list):
                    continue
                for part in item["content"]:
                    if isinstance(part, dict) and isinstance(part.get("text"), str):
                        return VolcengineArkProvider._decode_json(part["text"])
        raise DomainError(
            "INVALID_JSON",
            "Volcengine Ark response did not contain structured output",
            status_code=502,
            recoverable=True,
        )

    @staticmethod
    def _decode_json(value: str) -> JsonObject:
        text = value.strip()
        if text.startswith("```"):
            lines = text.splitlines()
            text = "\n".join(lines[1:-1]).strip()
        try:
            decoded = json.loads(text)
        except json.JSONDecodeError as error:
            raise DomainError(
                "INVALID_JSON",
                "Volcengine Ark returned invalid JSON",
                status_code=502,
                recoverable=True,
            ) from error
        if not isinstance(decoded, dict):
            raise DomainError(
                "INVALID_JSON",
                "Provider output must be an object",
                status_code=502,
                recoverable=True,
            )
        return decoded

    @staticmethod
    def _media_ids(input_data: JsonObject) -> list[str]:
        candidates: list[object] = []
        reference_asset = input_data.get("reference_asset")
        if isinstance(reference_asset, dict):
            candidates.append(reference_asset.get("media_asset_id"))
        candidates.append(input_data.get("scene_asset_id"))
        capture = input_data.get("capture")
        if isinstance(capture, dict):
            candidates.append(capture.get("media_asset_id"))
        previous_capture = input_data.get("previous_capture")
        if isinstance(previous_capture, dict):
            candidates.insert(-1, previous_capture.get("media_asset_id"))
        result: list[str] = []
        for candidate in candidates:
            if isinstance(candidate, str) and candidate not in result:
                result.append(candidate)
        return result


class HybridProvider:
    name = "hybrid"
    execution_mode = "live"

    def __init__(
        self,
        fixture: FixtureProvider,
        live: StructuredModelProvider,
    ) -> None:
        self.fixture = fixture
        self.live = live

    async def aclose(self) -> None:
        close = getattr(self.live, "aclose", None)
        if close is not None:
            await close()

    async def invoke(
        self,
        skill_name: str,
        input_data: JsonObject,
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        provider = self.fixture if self._uses_fixture(skill_name, input_data) else self.live
        result = await provider.invoke(skill_name, input_data, repair_error=repair_error)
        return replace(
            result,
            execution_mode=provider.execution_mode,
            provider_name=provider.name,
        )

    @staticmethod
    def _uses_fixture(skill_name: str, input_data: JsonObject) -> bool:
        if skill_name == "content_composer":
            return True
        if skill_name == "scene_adaptation":
            return False
        reference_asset = input_data.get("reference_asset")
        is_preset = (
            isinstance(reference_asset, dict) and reference_asset.get("source_type") == "preset"
        )
        if skill_name == "reference_understanding":
            return is_preset
        return is_preset and input_data.get("mode") == "original_replication"
