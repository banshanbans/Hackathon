"""FastAPI composition root for the W3 cross-client vertical slice."""

import asyncio
import logging
from collections.abc import Awaitable, Callable
from contextlib import asynccontextmanager, suppress
from typing import Literal
from uuid import uuid4

from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict

from app import __version__
from app.api.routes import router
from app.application.capture_authorization import CaptureAuthorizationService
from app.application.handoff import HandoffService
from app.application.service import W1Service
from app.config import Settings, get_settings
from app.domain.errors import DomainError
from app.handoff.rate_limit import MemoryHandoffRateLimiter, RedisHandoffRateLimiter
from app.handoff.tokens import HandoffTokenSigner
from app.media.service import MediaService
from app.media.storage import MemoryObjectStorage, ObjectStorage, S3ObjectStorage
from app.persistence.postgres import PostgresStateStore
from app.persistence.store import MemoryStateStore, StateStore
from app.providers.ark import HybridProvider, VolcengineArkProvider
from app.providers.base import StructuredModelProvider
from app.providers.mock import (
    DeterministicMockProvider,
    FixtureProvider,
    SafeRuleFallbackProvider,
    UnconfiguredProvider,
)
from app.skills.registry import SkillRegistry
from app.skills.runtime import build_skills

logger = logging.getLogger("soloshot.main")


class HealthResponse(BaseModel):
    """Stable liveness response that contains no configuration secrets."""

    model_config = ConfigDict(extra="forbid")

    schema_version: Literal["1.0"] = "1.0"
    request_id: str
    status: Literal["ok"] = "ok"
    service: Literal["soloshot-api"] = "soloshot-api"
    version: str = __version__


def create_app(
    store: StateStore | None = None,
    settings: Settings | None = None,
) -> FastAPI:
    resolved_settings = settings or get_settings()
    resolved_store = store or PostgresStateStore(resolved_settings.database_url)
    storage: ObjectStorage
    if isinstance(resolved_store, MemoryStateStore):
        storage = MemoryObjectStorage()
    else:
        storage = S3ObjectStorage(
            endpoint=resolved_settings.object_storage_endpoint,
            public_endpoint=resolved_settings.object_storage_public_endpoint,
            bucket=resolved_settings.object_storage_bucket,
            access_key=resolved_settings.object_storage_access_key,
            secret_key=resolved_settings.object_storage_secret_key,
        )
    media_service = MediaService(
        resolved_store,
        storage,
        retention_hours=resolved_settings.media_retention_hours,
        upload_ttl_seconds=resolved_settings.media_upload_ttl_seconds,
        access_ttl_seconds=resolved_settings.media_access_ttl_seconds,
    )
    rate_limiter = (
        MemoryHandoffRateLimiter()
        if isinstance(resolved_store, MemoryStateStore)
        else RedisHandoffRateLimiter(resolved_settings.redis_url)
    )
    handoff_signer = HandoffTokenSigner(resolved_settings.handoff_signing_secret)
    handoff_service = HandoffService(
        resolved_store,
        media_service,
        handoff_signer,
        rate_limiter,
        public_base_url=resolved_settings.public_handoff_base_url,
        handoff_ttl_seconds=resolved_settings.handoff_ttl_seconds,
        claim_token_ttl_seconds=resolved_settings.handoff_claim_token_ttl_seconds,
        lookup_limit_per_minute=resolved_settings.handoff_lookup_limit_per_minute,
        claim_limit_per_minute=resolved_settings.handoff_claim_limit_per_minute,
    )
    provider: StructuredModelProvider
    if resolved_settings.mock_ai_enabled and resolved_settings.model_provider == "mock":
        provider = DeterministicMockProvider()
    elif resolved_settings.model_provider == "rule_fallback":
        provider = SafeRuleFallbackProvider()
    elif resolved_settings.model_provider in {"hybrid", "volcengine_ark"}:
        live: StructuredModelProvider
        if resolved_settings.ark_api_key and resolved_settings.ark_model_id:
            live = VolcengineArkProvider(
                api_key=resolved_settings.ark_api_key,
                model_id=resolved_settings.ark_model_id,
                base_url=resolved_settings.ark_base_url,
                timeout_seconds=resolved_settings.ark_timeout_seconds,
                media_loader=media_service.load_for_model,
            )
        else:
            live = UnconfiguredProvider()
        provider = (
            HybridProvider(FixtureProvider(), live)
            if resolved_settings.model_provider == "hybrid"
            else live
        )
    else:
        provider = UnconfiguredProvider()
    registry = SkillRegistry(
        build_skills(
            provider,
            resolved_settings.skill_timeout_seconds,
            resolved_settings.scene_adaptation_timeout_seconds,
        )
    )
    capture_authorization = CaptureAuthorizationService(resolved_store, handoff_signer)

    async def cleanup_media_loop() -> None:
        while True:
            try:
                deleted = await media_service.cleanup_expired()
                if deleted:
                    logger.info("expired_media_deleted count=%d", deleted)
                expired_handoffs = await handoff_service.cleanup_expired()
                if expired_handoffs:
                    logger.info("expired_handoffs_marked count=%d", expired_handoffs)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("expired_media_cleanup_failed")
            await asyncio.sleep(3600)

    @asynccontextmanager
    async def lifespan(application: FastAPI):
        cleanup_task = asyncio.create_task(cleanup_media_loop())
        try:
            yield
        finally:
            cleanup_task.cancel()
            with suppress(asyncio.CancelledError):
                await cleanup_task
            close_provider = getattr(provider, "aclose", None)
            if close_provider is not None:
                await close_provider()
            await rate_limiter.aclose()
            close_store = getattr(resolved_store, "close", None)
            if close_store is not None:
                await close_store()

    application = FastAPI(
        title="SoloShot AI API",
        version=__version__,
        description="W3 adds secure H5 to iOS handoff to the persistent W2 flow.",
        lifespan=lifespan,
    )
    application.add_middleware(
        CORSMiddleware,
        allow_origins=resolved_settings.allowed_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
        allow_headers=[
            "Content-Type",
            "Idempotency-Key",
            "X-Request-ID",
            "X-Handoff-Management-Token",
            "X-Handoff-Claim-Token",
        ],
        expose_headers=["X-Request-ID", "X-SoloShot-Execution-Mode"],
    )
    application.state.w1_service = W1Service(
        resolved_store,
        registry,
        provider.name,
        provider.execution_mode,
        media_service,
        capture_authorization,
    )
    application.state.handoff_service = handoff_service
    application.state.object_storage = storage
    application.state.media_service = media_service
    application.include_router(router)

    @application.middleware("http")
    async def request_id_middleware(
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        supplied = request.headers.get("X-Request-ID", "")
        request_id = supplied if 0 < len(supplied) <= 128 and supplied.isascii() else str(uuid4())
        request.state.request_id = request_id
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        return response

    @application.exception_handler(DomainError)
    async def domain_error_handler(request: Request, error: DomainError) -> JSONResponse:
        response = JSONResponse(
            status_code=error.status_code,
            content={
                "error": {
                    "schema_version": "1.0",
                    "request_id": request.state.request_id,
                    "code": error.code,
                    "message": error.message,
                    "recoverable": error.recoverable,
                    "retry_after": error.retry_after,
                }
            },
        )
        response.headers["X-Request-ID"] = request.state.request_id
        if error.retry_after is not None:
            response.headers["Retry-After"] = str(error.retry_after)
        return response

    @application.exception_handler(RequestValidationError)
    async def request_validation_handler(
        request: Request, error: RequestValidationError
    ) -> JSONResponse:
        schema_version_error = any(
            "schema_version" in validation.get("loc", ()) and validation.get("input") != "1.0"
            for validation in error.errors()
        )
        response = JSONResponse(
            status_code=422,
            content={
                "error": {
                    "schema_version": "1.0",
                    "request_id": request.state.request_id,
                    "code": (
                        "SCHEMA_VERSION_UNSUPPORTED"
                        if schema_version_error
                        else "VALIDATION_FAILED"
                    ),
                    "message": (
                        "Only schema_version 1.0 is supported"
                        if schema_version_error
                        else "Request failed schema validation"
                    ),
                    "recoverable": False,
                    "retry_after": None,
                }
            },
        )
        response.headers["X-Request-ID"] = request.state.request_id
        return response

    @application.get("/health", response_model=HealthResponse, tags=["system"])
    async def health(request: Request) -> HealthResponse:
        return HealthResponse(request_id=request.state.request_id)

    return application


app = create_app()
