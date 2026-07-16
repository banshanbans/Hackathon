"""FastAPI entry point for the W0 service skeleton."""

from collections.abc import Awaitable, Callable
from typing import Literal
from uuid import uuid4

from fastapi import FastAPI, Request, Response
from pydantic import BaseModel, ConfigDict

from app import __version__


class HealthResponse(BaseModel):
    """Stable liveness response that contains no configuration secrets."""

    model_config = ConfigDict(extra="forbid")

    schema_version: Literal["1.0"] = "1.0"
    request_id: str
    status: Literal["ok"] = "ok"
    service: Literal["soloshot-api"] = "soloshot-api"
    version: str = __version__


app = FastAPI(
    title="SoloShot AI API",
    version=__version__,
    description="W0 exposes liveness only; /api/v1 behavior begins in later work packages.",
)


@app.middleware("http")
async def request_id_middleware(
    request: Request,
    call_next: Callable[[Request], Awaitable[Response]],
) -> Response:
    """Attach a request id without trusting arbitrary unsanitized header values."""

    supplied = request.headers.get("X-Request-ID", "")
    request_id = supplied if 0 < len(supplied) <= 128 and supplied.isascii() else str(uuid4())
    request.state.request_id = request_id
    response = await call_next(request)
    response.headers["X-Request-ID"] = request_id
    return response


@app.get("/health", response_model=HealthResponse, tags=["system"])
async def health(request: Request) -> HealthResponse:
    """Return process liveness; dependency readiness is checked by Compose health checks."""

    return HealthResponse(request_id=request.state.request_id)

