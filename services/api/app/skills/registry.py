from __future__ import annotations

from app.domain.errors import DomainError
from app.skills.runtime import Skill


class SkillRegistry:
    def __init__(self, skills: dict[tuple[str, str], Skill]) -> None:
        self._skills = skills

    def get(self, name: str, version: str = "1.0.0") -> Skill:
        skill = self._skills.get((name, version))
        if skill is not None:
            return skill
        if any(registered_name == name for registered_name, _ in self._skills):
            raise DomainError(
                "SKILL_VERSION_UNSUPPORTED",
                f"Skill {name} version {version} is unavailable",
                status_code=422,
            )
        raise DomainError("SKILL_NOT_FOUND", f"Skill {name} is unavailable in W1", status_code=404)
