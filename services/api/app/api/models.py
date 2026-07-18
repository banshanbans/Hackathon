from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import Field

from app.domain.models import (
    AgentIntent,
    JsonObject,
    NormalizedBoundingBox,
    ReferenceAsset,
    SchemaVersion,
    StrictModel,
    UserConstraints,
)


class CreateSessionRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    source_channel: Literal["h5_qr", "h5_direct", "ios", "demo_preset", "shared_link"]
    mode: Literal["original_replication", "scene_adaptation"]
    user_constraints: UserConstraints
    external_ai_consent: bool = False


class AnalyzeReferenceRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    reference_asset: ReferenceAsset


class AdaptReferenceRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    reference_id: str = Field(pattern=r"^ref_[A-Za-z0-9_-]+$")
    scene_asset_id: str = Field(pattern=r"^media_[A-Za-z0-9_-]+$")


class CreateMediaUploadRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    purpose: Literal["reference", "scene", "capture"]
    content_type: Literal["image/jpeg", "image/png", "image/webp"]
    byte_size: int = Field(ge=1, le=8_000_000)
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")


class CompleteMediaUploadRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")


EventName = Literal[
    "page_view",
    "reference_select",
    "reference_upload",
    "circle_complete",
    "replicate_click",
    "mode_select",
    "agent_start",
    "agent_success",
    "agent_fail",
    "shot_plan_view",
    "h5_capture_start",
    "result_upload",
    "result_evaluated",
    "handoff_qr_create",
    "handoff_claimed",
    "share_click",
    "publish_preview",
]


class AnalyticsEventRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    event_id: str = Field(min_length=36, max_length=36)
    event_name: EventName
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    source_channel: Literal["h5_qr", "h5_direct", "ios", "demo_preset", "shared_link"]
    client: Literal["h5", "ios", "api"]
    timestamp: datetime
    properties: JsonObject


class EventBatchRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    events: list[AnalyticsEventRequest] = Field(min_length=1, max_length=100)


class ValidateReferenceBoxRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    reference_id: str = Field(pattern=r"^ref_[A-Za-z0-9_-]+$")
    selected_box: NormalizedBoundingBox


class CreateAgentRunRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    intent: AgentIntent


class ContinueAgentRunRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    capture_id: str = Field(pattern=r"^cap_[A-Za-z0-9_-]+$")


class InvokeSkillRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    skill_version: str = Field(pattern=r"^[0-9]+\.[0-9]+\.[0-9]+$")
    input: dict[str, Any]


class CreateCaptureRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    round_index: int = Field(ge=1, le=2)
    media_asset_id: str = Field(pattern=r"^media_[A-Za-z0-9_-]+$")


class SelectFrameRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    frame_id: str = Field(pattern=r"^frame_[A-Za-z0-9_-]+$")


class CreateEvaluationRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    capture_id: str = Field(pattern=r"^cap_[A-Za-z0-9_-]+$")


class CreateHandoffRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")


class ClaimHandoffRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    client_instance_id: str = Field(min_length=8, max_length=128)


class CompleteHandoffRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    client_instance_id: str = Field(min_length=8, max_length=128)


class RenderPostRequest(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    format: Literal["before_after_image", "vertical_video", "both"]
