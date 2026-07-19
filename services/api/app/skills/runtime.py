from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from time import perf_counter

from pydantic import BaseModel, ValidationError

from app.domain.errors import DomainError
from app.domain.ids import new_id
from app.domain.models import (
    Capture,
    JsonObject,
    PostJob,
    ReferenceAnalysis,
    ReferenceAsset,
    ResultEvaluation,
    ShotPlan,
    SkillName,
    SkillRef,
    SkillRun,
    UserConstraints,
)
from app.providers.base import StructuredModelProvider

logger = logging.getLogger("soloshot.skills")


@dataclass(frozen=True)
class SkillInvocation:
    run: SkillRun
    output: JsonObject
    execution_mode: str


class Skill:
    version = "1.0.0"

    def __init__(
        self,
        name: SkillName,
        output_model: type[BaseModel],
        provider: StructuredModelProvider,
        timeout_seconds: float,
        version: str = "1.0.0",
    ) -> None:
        self.name = name
        self.output_model = output_model
        self.provider = provider
        self.timeout_seconds = timeout_seconds
        self.version = version

    def validate_input(self, input_data: JsonObject) -> None:
        try:
            if self.name == "reference_understanding":
                ReferenceAsset.model_validate(input_data.get("reference_asset"))
            elif self.name == "shooting_plan":
                ReferenceAsset.model_validate(input_data.get("reference_asset"))
                ReferenceAnalysis.model_validate(input_data.get("reference_analysis"))
                UserConstraints.model_validate(input_data.get("user_constraints"))
                if input_data.get("mode") not in {"original_replication", "scene_adaptation"}:
                    raise ValueError("mode is invalid")
            elif self.name == "scene_adaptation":
                ReferenceAsset.model_validate(input_data.get("reference_asset"))
                ReferenceAnalysis.model_validate(input_data.get("reference_analysis"))
                UserConstraints.model_validate(input_data.get("user_constraints"))
                scene_asset_id = input_data.get("scene_asset_id")
                if not isinstance(scene_asset_id, str) or not scene_asset_id.startswith("media_"):
                    raise ValueError("scene_asset_id is invalid")
            elif self.name == "result_evaluation":
                ReferenceAsset.model_validate(input_data.get("reference_asset"))
                ReferenceAnalysis.model_validate(input_data.get("reference_analysis"))
                Capture.model_validate(input_data.get("capture"))
                ShotPlan.model_validate(input_data.get("shot_plan"))
                if input_data.get("mode") not in {"original_replication", "scene_adaptation"}:
                    raise ValueError("mode is invalid")
                if self.version == "1.1.0":
                    if input_data.get("media_kind") != "selected_frame":
                        raise ValueError("media_kind must be selected_frame")
                    round_index = input_data.get("round_index")
                    if round_index not in {1, 2}:
                        raise ValueError("round_index is invalid")
                    if round_index == 2:
                        Capture.model_validate(input_data.get("previous_capture"))
                        ResultEvaluation.model_validate(input_data.get("previous_evaluation"))
            elif self.name == "content_composer":
                if not isinstance(input_data.get("session_id"), str):
                    raise ValueError("session_id is required")
                if input_data.get("format") not in {
                    "before_after_image",
                    "vertical_video",
                    "both",
                }:
                    raise ValueError("format is invalid")
        except (ValidationError, ValueError) as error:
            raise DomainError("VALIDATION_FAILED", str(error)) from error

    async def invoke(self, input_data: JsonObject) -> SkillInvocation:
        self.validate_input(input_data)
        started = perf_counter()
        repair_count = 0
        try:
            async with asyncio.timeout(self.timeout_seconds):
                result = await self.provider.invoke(self.name, input_data)
                try:
                    output_model = self._validate_output(result.output, input_data)
                except (ValidationError, ValueError) as first_error:
                    repair_count = 1
                    result = await self.provider.invoke(
                        self.name,
                        input_data,
                        repair_error=str(first_error),
                    )
                    try:
                        output_model = self._validate_output(result.output, input_data)
                    except (ValidationError, ValueError) as final_error:
                        raise DomainError(
                            "INVALID_JSON",
                            f"Provider output for {self.name} failed after one repair",
                            status_code=502,
                            recoverable=True,
                        ) from final_error
        except TimeoutError as error:
            raise DomainError(
                "MODEL_TIMEOUT",
                f"Skill {self.name} exceeded its {self.timeout_seconds:g}s timeout",
                status_code=503,
                recoverable=True,
            ) from error

        latency_ms = max(0, round((perf_counter() - started) * 1000))
        warnings = list(result.warnings)
        if repair_count:
            warnings.append("STRUCTURED_OUTPUT_REPAIRED_ONCE")
        execution_mode = result.execution_mode or self.provider.execution_mode
        provider_name = result.provider_name or self.provider.name
        run = SkillRun(
            skill_run_id=new_id("skr"),
            skill=SkillRef(name=self.name, version=self.version),
            status="completed",
            latency_ms=latency_ms,
            estimated_cost_usd=result.estimated_cost_usd,
            confidence=result.confidence,
            fallback_used=execution_mode == "fallback",
            provider=provider_name,
            model=result.model,
            warnings=warnings,
            repair_count=repair_count,
            error_code=None,
        )
        logger.info(
            "skill_completed name=%s version=%s provider=%s mode=%s "
            "latency_ms=%d cost_usd=%.6f confidence=%.3f fallback=%s",
            self.name,
            self.version,
            provider_name,
            execution_mode,
            latency_ms,
            result.estimated_cost_usd,
            result.confidence,
            run.fallback_used,
        )
        output = output_model.model_dump(mode="json")
        return SkillInvocation(run=run, output=output, execution_mode=execution_mode)

    def _validate_output(self, output: JsonObject, input_data: JsonObject) -> BaseModel:
        model = self.output_model.model_validate(output)
        if (
            self.name == "result_evaluation"
            and self.version == "1.1.0"
            and input_data.get("media_kind") == "selected_frame"
            and getattr(model, "issue_code", None) == "motion_timing_wrong"
        ):
            raise ValueError("selected_frame cannot support motion_timing_wrong")
        return model


OUTPUT_MODELS: dict[str, type[BaseModel]] = {
    "reference_understanding": ReferenceAnalysis,
    "scene_adaptation": ReferenceAnalysis,
    "shooting_plan": ShotPlan,
    "result_evaluation": ResultEvaluation,
    "content_composer": PostJob,
}


def build_skills(
    provider: StructuredModelProvider, timeout_seconds: float
) -> dict[tuple[str, str], Skill]:
    skills = {
        (name, Skill.version): Skill(
            name=name,  # type: ignore[arg-type]
            output_model=model,
            provider=provider,
            timeout_seconds=timeout_seconds,
        )
        for name, model in OUTPUT_MODELS.items()
    }
    skills[("result_evaluation", "1.1.0")] = Skill(
        name="result_evaluation",
        output_model=ResultEvaluation,
        provider=provider,
        timeout_seconds=timeout_seconds,
        version="1.1.0",
    )
    return skills
