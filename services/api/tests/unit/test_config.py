from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.config import Settings


def test_live_model_timeouts_allow_slow_vision_calls_with_a_bounded_ceiling() -> None:
    settings = Settings(ark_timeout_seconds=60, skill_timeout_seconds=75)

    assert settings.ark_timeout_seconds == 60
    assert settings.skill_timeout_seconds == 75

    with pytest.raises(ValidationError):
        Settings(ark_timeout_seconds=121)
    with pytest.raises(ValidationError):
        Settings(skill_timeout_seconds=121)
