from __future__ import annotations

from functools import lru_cache

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_env: str = "development"
    database_url: str = "postgresql://soloshot:local-development-only@localhost:5432/soloshot"
    model_provider: str = "unconfigured"
    mock_ai_enabled: bool = False
    skill_timeout_seconds: float = Field(default=8.0, gt=0, le=120)
    scene_adaptation_timeout_seconds: float = Field(default=35.0, gt=0, le=120)
    h5_allowed_origins: str = "http://localhost:5173,http://127.0.0.1:5173"
    object_storage_endpoint: str = "http://localhost:9000"
    object_storage_public_endpoint: str = "http://localhost:9000"
    object_storage_bucket: str = "soloshot-media"
    object_storage_access_key: str = "soloshot-local"
    object_storage_secret_key: str = "local-development-only"
    media_retention_hours: int = Field(default=24, ge=1, le=168)
    media_upload_ttl_seconds: int = Field(default=600, ge=60, le=3600)
    media_access_ttl_seconds: int = Field(default=300, ge=60, le=3600)
    redis_url: str = "redis://localhost:6379/0"
    handoff_signing_secret: str = "local-development-handoff-secret-change-me"
    public_handoff_base_url: str = "http://localhost:5173/handoff"
    handoff_ttl_seconds: int = Field(default=600, ge=60, le=3600)
    handoff_claim_token_ttl_seconds: int = Field(default=86_400, ge=600, le=604_800)
    handoff_lookup_limit_per_minute: int = Field(default=120, ge=10, le=1000)
    handoff_claim_limit_per_minute: int = Field(default=10, ge=1, le=100)
    handoff_discovery_enabled: bool = False
    ark_api_key: str = ""
    ark_model_id: str = ""
    ark_base_url: str = "https://ark.cn-beijing.volces.com/api/v3"
    ark_timeout_seconds: float = Field(default=8.0, gt=0, le=120)

    @property
    def allowed_origins(self) -> list[str]:
        return [origin.strip() for origin in self.h5_allowed_origins.split(",") if origin.strip()]

    @model_validator(mode="after")
    def validate_handoff_secret(self) -> Settings:
        if self.app_env not in {"development", "test"} and (
            len(self.handoff_signing_secret) < 32
            or self.handoff_signing_secret.startswith("replace-me")
        ):
            raise ValueError("HANDOFF_SIGNING_SECRET must be a non-default 32+ character secret")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
