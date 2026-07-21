from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import pytest

from app.application.service import ServiceResult, W1Service
from app.domain.errors import DomainError
from app.providers.base import ProviderResult
from app.providers.mock import DeterministicMockProvider, SafeRuleFallbackProvider
from app.skills.registry import SkillRegistry
from app.skills.runtime import SkillInvocationError, build_skills


def test_registry_distinguishes_missing_skill_and_version() -> None:
    registry = SkillRegistry(build_skills(DeterministicMockProvider(), 8))
    with pytest.raises(DomainError, match="version") as version_error:
        registry.get("shooting_plan", "2.0.0")
    assert version_error.value.code == "SKILL_VERSION_UNSUPPORTED"

    with pytest.raises(DomainError, match="unavailable") as missing_error:
        registry.get("coaching_decision", "1.0.0")
    assert missing_error.value.code == "SKILL_NOT_FOUND"


class SlowProvider:
    name = "slow-test"
    execution_mode = "live"

    async def invoke(
        self,
        skill_name: str,
        input_data: dict[str, object],
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        await asyncio.sleep(0.02)
        return ProviderResult(output={}, confidence=1, model="slow")


def test_skill_timeout_fails_closed() -> None:
    registry = SkillRegistry(build_skills(SlowProvider(), 0.001))
    skill = registry.get("content_composer")
    with pytest.raises(DomainError) as timeout_error:
        asyncio.run(skill.invoke({"session_id": "ss_timeout", "format": "before_after_image"}))
    assert timeout_error.value.code == "MODEL_TIMEOUT"
    assert timeout_error.value.recoverable is True
    assert isinstance(timeout_error.value, SkillInvocationError)
    assert timeout_error.value.run.status == "failed"
    assert timeout_error.value.run.error_code == "MODEL_TIMEOUT"


def test_failed_skill_trace_is_persisted_outside_the_rolled_back_transaction() -> None:
    class RecordingStore:
        def __init__(self) -> None:
            self.skill_runs: list[dict[str, object]] = []

        @asynccontextmanager
        async def transaction(self) -> AsyncIterator[None]:
            yield

        async def get_idempotency(self, operation: str, key: str) -> None:
            return None

        async def put_skill_run(
            self,
            skill_run_id: str,
            run_id: str | None,
            session_id: str,
            position: int,
            run: dict[str, object],
            output: dict[str, object],
        ) -> None:
            self.skill_runs.append(run)

    async def scenario() -> RecordingStore:
        skill = SkillRegistry(build_skills(SlowProvider(), 0.001)).get("content_composer")
        try:
            await skill.invoke({"session_id": "ss_failed_trace", "format": "before_after_image"})
        except SkillInvocationError as error:
            failure = error.attach("ss_failed_trace", None, 0)
        else:  # pragma: no cover - the provider always exceeds the timeout
            raise AssertionError("expected the Skill to fail")

        store = RecordingStore()
        service = object.__new__(W1Service)
        service.store = store  # type: ignore[assignment]

        async def action() -> ServiceResult:
            raise failure

        with pytest.raises(SkillInvocationError):
            await service._idempotent("failed-skill", "key", {}, action)
        return store

    store = asyncio.run(scenario())
    assert len(store.skill_runs) == 1
    assert store.skill_runs[0]["status"] == "failed"
    assert store.skill_runs[0]["error_code"] == "MODEL_TIMEOUT"


class RepairingProvider:
    name = "repair-test"
    execution_mode = "live"

    def __init__(self) -> None:
        self.calls = 0

    async def invoke(
        self,
        skill_name: str,
        input_data: dict[str, object],
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        self.calls += 1
        if repair_error is None:
            return ProviderResult(output={}, confidence=0.8, model="repair-test")
        return await DeterministicMockProvider().invoke(
            skill_name,
            input_data,
            repair_error=repair_error,
        )


def test_skill_repairs_invalid_structure_at_most_once() -> None:
    provider = RepairingProvider()
    registry = SkillRegistry(build_skills(provider, 8))
    invocation = asyncio.run(
        registry.get("content_composer").invoke(
            {"session_id": "ss_repair", "format": "before_after_image"}
        )
    )
    assert provider.calls == 2
    assert invocation.run.repair_count == 1
    assert "STRUCTURED_OUTPUT_REPAIRED_ONCE" in invocation.run.warnings


def test_rule_fallback_is_low_confidence_and_evaluation_fails_closed() -> None:
    provider = SafeRuleFallbackProvider()
    registry = SkillRegistry(build_skills(provider, 8))
    reference = asyncio.run(
        registry.get("reference_understanding").invoke(
            {
                "reference_asset": {
                    "schema_version": "1.0",
                    "reference_id": "ref_fallback",
                    "media_type": "image",
                    "source_type": "preset",
                    "width": 100,
                    "height": 100,
                    "selected_box": {
                        "x": 0.2,
                        "y": 0.1,
                        "width": 0.4,
                        "height": 0.8,
                    },
                    "attribution": {"source_label": "fallback fixture"},
                }
            }
        )
    )
    assert reference.execution_mode == "fallback"
    assert reference.run.fallback_used is True
    assert reference.run.confidence == 0.35
    assert reference.run.warnings == ["RULE_FALLBACK_LOW_CONFIDENCE"]

    with pytest.raises(DomainError) as unavailable:
        asyncio.run(provider.invoke("result_evaluation", {}))
    assert unavailable.value.code == "PROVIDER_UNAVAILABLE"
