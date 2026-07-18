from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Request
from fastapi.responses import JSONResponse

from app.api.models import (
    AdaptReferenceRequest,
    AnalyzeReferenceRequest,
    ClaimHandoffRequest,
    CompleteHandoffRequest,
    CompleteMediaUploadRequest,
    ContinueAgentRunRequest,
    CreateAgentRunRequest,
    CreateCaptureRequest,
    CreateEvaluationRequest,
    CreateHandoffRequest,
    CreateMediaUploadRequest,
    CreateSessionRequest,
    EventBatchRequest,
    InvokeSkillRequest,
    RenderPostRequest,
    SelectFrameRequest,
    ValidateReferenceBoxRequest,
)
from app.application.handoff import HandoffService
from app.application.service import ServiceResult, W1Service

router = APIRouter(prefix="/api/v1")
IdempotencyKey = Annotated[str, Header(alias="Idempotency-Key", min_length=8, max_length=128)]
ManagementToken = Annotated[
    str, Header(alias="X-Handoff-Management-Token", min_length=32, max_length=2048)
]
ClaimToken = Annotated[
    str, Header(alias="X-Handoff-Claim-Token", min_length=32, max_length=2048)
]


def service(request: Request) -> W1Service:
    return request.app.state.w1_service


ServiceDep = Annotated[W1Service, Depends(service)]


def handoff_service(request: Request) -> HandoffService:
    return request.app.state.handoff_service


HandoffServiceDep = Annotated[HandoffService, Depends(handoff_service)]


def rate_identity(request: Request) -> str:
    return request.client.host if request.client is not None else "unknown"


def response(request: Request, result: ServiceResult) -> JSONResponse:
    headers: dict[str, str] = {}
    if result.execution_mode is not None:
        headers["X-SoloShot-Execution-Mode"] = result.execution_mode
    return JSONResponse(
        status_code=result.status_code,
        content={
            "schema_version": "1.0",
            "request_id": request.state.request_id,
            "data": result.data,
        },
        headers=headers,
    )


@router.post("/sessions", tags=["sessions"])
async def create_session(
    request: Request,
    body: CreateSessionRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.create_session(body.model_dump(mode="json"), idempotency_key),
    )


@router.get("/sessions/{session_id}", tags=["sessions"])
async def get_session(request: Request, session_id: str, w1: ServiceDep) -> JSONResponse:
    return response(request, await w1.get_session(session_id))


@router.delete("/sessions/{session_id}", tags=["sessions"])
async def delete_session(
    request: Request,
    session_id: str,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(request, await w1.delete_session(session_id, idempotency_key))


@router.post("/media/uploads", tags=["media"])
async def create_media_upload(
    request: Request,
    body: CreateMediaUploadRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.create_media_upload(body.model_dump(mode="json"), idempotency_key),
    )


@router.post("/media/uploads/{media_asset_id}/complete", tags=["media"])
async def complete_media_upload(
    request: Request,
    media_asset_id: str,
    body: CompleteMediaUploadRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.complete_media_upload(
            media_asset_id, body.model_dump(mode="json"), idempotency_key
        ),
    )


@router.get("/media/{media_asset_id}/access", tags=["media"])
async def get_media_access(
    request: Request,
    media_asset_id: str,
    session_id: Annotated[str, Query(pattern=r"^ss_[A-Za-z0-9_-]+$")],
    w1: ServiceDep,
) -> JSONResponse:
    return response(request, await w1.get_media_access(media_asset_id, session_id))


@router.post("/references/analyze", tags=["references"])
async def analyze_reference(
    request: Request,
    body: AnalyzeReferenceRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.analyze_reference(body.model_dump(mode="json"), idempotency_key),
    )


@router.post("/references/validate-box", tags=["references"])
async def validate_reference_box(
    request: Request,
    body: ValidateReferenceBoxRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.validate_reference_box(body.model_dump(mode="json"), idempotency_key),
    )


@router.post("/references/adapt", tags=["references"])
async def adapt_reference(
    request: Request,
    body: AdaptReferenceRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.adapt_reference(body.model_dump(mode="json"), idempotency_key),
    )


@router.get("/references/{reference_id}", tags=["references"])
async def get_reference(request: Request, reference_id: str, w1: ServiceDep) -> JSONResponse:
    return response(request, await w1.get_reference(reference_id))


@router.post("/agent/runs", tags=["agent"])
async def create_agent_run(
    request: Request,
    body: CreateAgentRunRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.create_agent_run(body.model_dump(mode="json"), idempotency_key),
    )


@router.post("/agent/runs/{run_id}/continue", tags=["agent"])
async def continue_agent_run(
    request: Request,
    run_id: str,
    body: ContinueAgentRunRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.continue_agent_run(run_id, body.model_dump(mode="json"), idempotency_key),
    )


@router.get("/agent/runs/{run_id}", tags=["agent"])
async def get_agent_run(request: Request, run_id: str, w1: ServiceDep) -> JSONResponse:
    return response(request, await w1.get_agent_run(run_id))


@router.get("/agent/runs/{run_id}/trace", tags=["agent"])
async def get_agent_trace(request: Request, run_id: str, w1: ServiceDep) -> JSONResponse:
    return response(request, await w1.get_agent_trace(run_id))


@router.post("/skills/{skill_name}/invoke", tags=["skills"])
async def invoke_skill(
    request: Request,
    skill_name: str,
    body: InvokeSkillRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.invoke_skill(skill_name, body.model_dump(mode="json"), idempotency_key),
    )


@router.post("/captures", tags=["captures"])
async def create_capture(
    request: Request,
    body: CreateCaptureRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.create_capture(body.model_dump(mode="json"), idempotency_key),
    )


@router.get("/captures/{capture_id}", tags=["captures"])
async def get_capture(request: Request, capture_id: str, w1: ServiceDep) -> JSONResponse:
    return response(request, await w1.get_capture(capture_id))


@router.post("/captures/{capture_id}/select-frame", tags=["captures"])
async def select_frame(
    request: Request,
    capture_id: str,
    body: SelectFrameRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.select_frame(capture_id, body.model_dump(mode="json"), idempotency_key),
    )


@router.post("/evaluations", tags=["evaluations"])
async def create_evaluation(
    request: Request,
    body: CreateEvaluationRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.create_evaluation(body.model_dump(mode="json"), idempotency_key),
    )


@router.post("/handoffs", tags=["handoffs"])
async def create_handoff(
    request: Request,
    body: CreateHandoffRequest,
    idempotency_key: IdempotencyKey,
    handoffs: HandoffServiceDep,
) -> JSONResponse:
    return response(
        request,
        await handoffs.create(body.model_dump(mode="json"), idempotency_key),
    )


@router.get("/handoffs/{code}", tags=["handoffs"])
async def get_handoff(
    request: Request, code: str, handoffs: HandoffServiceDep
) -> JSONResponse:
    return response(request, await handoffs.get(code.upper(), rate_identity(request)))


@router.post("/handoffs/{code}/claim", tags=["handoffs"])
async def claim_handoff(
    request: Request,
    code: str,
    body: ClaimHandoffRequest,
    idempotency_key: IdempotencyKey,
    handoffs: HandoffServiceDep,
) -> JSONResponse:
    return response(
        request,
        await handoffs.claim(
            code.upper(),
            body.model_dump(mode="json"),
            idempotency_key,
            rate_identity(request),
        ),
    )


@router.post("/handoffs/{code}/complete", tags=["handoffs"])
async def complete_handoff(
    request: Request,
    code: str,
    body: CompleteHandoffRequest,
    idempotency_key: IdempotencyKey,
    claim_token: ClaimToken,
    handoffs: HandoffServiceDep,
) -> JSONResponse:
    return response(
        request,
        await handoffs.complete(
            code.upper(), body.model_dump(mode="json"), claim_token, idempotency_key
        ),
    )


@router.delete("/handoffs/{code}", tags=["handoffs"])
async def revoke_handoff(
    request: Request,
    code: str,
    idempotency_key: IdempotencyKey,
    management_token: ManagementToken,
    handoffs: HandoffServiceDep,
) -> JSONResponse:
    return response(
        request,
        await handoffs.revoke(code.upper(), management_token, idempotency_key),
    )


@router.post("/posts/render", tags=["content"])
async def render_post(
    request: Request,
    body: RenderPostRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.render_post(body.model_dump(mode="json"), idempotency_key),
    )


@router.get("/posts/{post_id}", tags=["content"])
async def get_post(request: Request, post_id: str, w1: ServiceDep) -> JSONResponse:
    return response(request, await w1.get_post(post_id))


@router.post("/events/batch", tags=["analytics"])
async def put_events(
    request: Request,
    body: EventBatchRequest,
    idempotency_key: IdempotencyKey,
    w1: ServiceDep,
) -> JSONResponse:
    return response(
        request,
        await w1.put_events(body.model_dump(mode="json"), idempotency_key),
    )
