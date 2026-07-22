from __future__ import annotations

from app.domain.errors import DomainError
from app.domain.ids import new_id
from app.domain.models import JsonObject, ReferenceAnalysis, UserConstraints
from app.domain.shot_plan_rules import RULE_PROVIDER_NAME, build_scene_adaptation_plan
from app.providers.base import ProviderResult


class SceneShotPlanRuleProvider:
    name = RULE_PROVIDER_NAME
    execution_mode = "live"

    async def invoke(
        self,
        skill_name: str,
        input_data: JsonObject,
        *,
        repair_error: str | None = None,
    ) -> ProviderResult:
        if skill_name != "shooting_plan" or input_data.get("mode") != "scene_adaptation":
            raise DomainError(
                "VALIDATION_FAILED",
                "shooting_plan@1.1.0 only supports scene_adaptation",
                status_code=422,
            )
        analysis = ReferenceAnalysis.model_validate(input_data.get("reference_analysis"))
        constraints = UserConstraints.model_validate(input_data.get("user_constraints"))
        result = build_scene_adaptation_plan(analysis, constraints, plan_id=new_id("sp"))
        return ProviderResult(
            output=result.plan.model_dump(mode="json"),
            confidence=result.plan.confidence,
            model=None,
            estimated_cost_usd=0,
            warnings=result.warnings,
            execution_mode="live",
            provider_name=self.name,
        )
