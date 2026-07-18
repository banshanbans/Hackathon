from __future__ import annotations

from datetime import UTC, datetime

from app.domain.ids import new_id
from app.domain.models import AgentIntent, AgentRun, SkillRun


def new_agent_run(
    session_id: str, intent: AgentIntent, provider: str, model: str | None
) -> AgentRun:
    return AgentRun(
        run_id=new_id("run"),
        session_id=session_id,
        intent=intent,
        selected_skills=[],
        provider=provider,
        model=model,
        status="running",
        latency_ms=0,
        estimated_cost_usd=0,
        confidence=1,
        fallback_used=False,
        error_code=None,
        trace_id=new_id("trace"),
        created_at=datetime.now(UTC),
    )


def append_skill_runs(agent_run: AgentRun, skill_runs: list[SkillRun]) -> AgentRun:
    confidences = [agent_run.confidence, *(run.confidence for run in skill_runs)]
    models = [
        model
        for model in [agent_run.model, *(run.model for run in skill_runs)]
        if model is not None
    ]
    return agent_run.model_copy(
        update={
            "selected_skills": [
                *agent_run.selected_skills,
                *(run.skill for run in skill_runs),
            ],
            "status": "completed",
            "latency_ms": agent_run.latency_ms + sum(run.latency_ms for run in skill_runs),
            "estimated_cost_usd": agent_run.estimated_cost_usd
            + sum(run.estimated_cost_usd for run in skill_runs),
            "confidence": min(confidences),
            "model": (
                models[0] if models and len(set(models)) == 1 else ("mixed" if models else None)
            ),
            "fallback_used": agent_run.fallback_used
            or any(run.fallback_used for run in skill_runs),
        }
    )
