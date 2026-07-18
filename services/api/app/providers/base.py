from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

from app.domain.models import JsonObject


@dataclass(frozen=True)
class ProviderResult:
    output: JsonObject
    confidence: float
    model: str | None
    estimated_cost_usd: float = 0.0
    warnings: list[str] = field(default_factory=list)
    repair_count: int = 0
    execution_mode: str | None = None
    provider_name: str | None = None


class StructuredModelProvider(Protocol):
    name: str
    execution_mode: str

    async def invoke(
        self,
        skill_name: str,
        input_data: JsonObject,
        *,
        repair_error: str | None = None,
    ) -> ProviderResult: ...
