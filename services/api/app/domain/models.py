from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

JsonObject = dict[str, Any]
SchemaVersion = Literal["1.0"]
SessionState = Literal[
    "created",
    "reference_ready",
    "analyzing",
    "shot_plan_ready",
    "handoff_ready",
    "capturing",
    "evaluating",
    "coaching",
    "completed",
    "failed",
    "deleted",
]
AgentIntent = Literal[
    "original_replication",
    "scene_adaptation",
    "result_evaluation",
    "continue_coaching",
    "content_generation",
    "creator_template_generation",
]
SkillName = Literal[
    "reference_understanding",
    "shooting_plan",
    "scene_adaptation",
    "result_evaluation",
    "coaching_decision",
    "content_composer",
    "growth_analytics",
]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class NormalizedPoint(StrictModel):
    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)


class NormalizedBoundingBox(StrictModel):
    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)
    width: float = Field(gt=0, le=1)
    height: float = Field(gt=0, le=1)

    @model_validator(mode="after")
    def fits_frame(self) -> NormalizedBoundingBox:
        if self.x + self.width > 1 or self.y + self.height > 1:
            raise ValueError("selected_box must fit inside normalized frame")
        return self


class Attribution(StrictModel):
    source_label: str = Field(min_length=1, max_length=100)
    creator_label: str | None = Field(default=None, max_length=100)
    source_url: str | None = None


class ReferenceAsset(StrictModel):
    schema_version: SchemaVersion = "1.0"
    reference_id: str = Field(pattern=r"^ref_[A-Za-z0-9_-]+$")
    media_asset_id: str | None = Field(default=None, pattern=r"^media_[A-Za-z0-9_-]+$")
    media_type: Literal["image", "video_frame"]
    source_type: Literal["upload", "preset"]
    width: int = Field(ge=1)
    height: int = Field(ge=1)
    selected_box: NormalizedBoundingBox
    attribution: Attribution


class TargetLayout(StrictModel):
    center_x: float = Field(ge=0, le=1)
    center_y: float = Field(ge=0, le=1)
    width: float = Field(gt=0, le=1)
    height: float = Field(gt=0, le=1)
    head_point: NormalizedPoint
    foot_line_y: float = Field(ge=0, le=1)
    body_direction: Literal["front", "back", "left", "right", "slightly_left", "slightly_right"]
    pose_template: str = Field(min_length=1, max_length=100)


class ReferenceAnalysis(StrictModel):
    schema_version: SchemaVersion = "1.0"
    analysis_id: str = Field(pattern=r"^ra_[A-Za-z0-9_-]+$")
    reference_id: str = Field(pattern=r"^ref_[A-Za-z0-9_-]+$")
    person_count: int = Field(ge=0)
    target_layout: TargetLayout
    composition_notes: list[str] = Field(default_factory=list, max_length=10)
    safety_status: Literal["safe", "warn", "block"] = "safe"
    safety_warnings: list[str] = Field(default_factory=list, max_length=10)
    confidence: float = Field(ge=0, le=1)


class UserConstraints(StrictModel):
    solo_traveler: bool
    tripod_available: bool
    has_luggage: bool
    notes: str | None = Field(default=None, max_length=500)


class SkillRef(StrictModel):
    name: SkillName
    version: str = Field(pattern=r"^[0-9]+\.[0-9]+\.[0-9]+$")


class ActionStep(StrictModel):
    sequence: int = Field(ge=1)
    instruction: str = Field(min_length=1, max_length=160)
    duration_seconds: float = Field(gt=0, le=30)


class ExecutionPlan(StrictModel):
    supported: bool
    instruction: str = Field(min_length=1, max_length=300)
    requires_realtime_alignment: bool = False


class ShotPlan(StrictModel):
    schema_version: SchemaVersion = "1.0"
    plan_id: str = Field(pattern=r"^sp_[A-Za-z0-9_-]+$")
    camera_height: Literal["ground", "knee", "waist", "chest", "eye", "overhead"]
    camera_angle: Literal["level", "slight_up", "slight_down"]
    lens: Literal["0.5x", "1x", "2x"]
    capture_mode: Literal["photo", "short_video"]
    phone_setup_instruction: str = Field(min_length=1, max_length=300)
    target_layout: TargetLayout
    action_script: list[ActionStep] = Field(min_length=1, max_length=10)
    safety_notes: list[str] = Field(min_length=1, max_length=10)
    h5_execution: ExecutionPlan
    ios_execution: ExecutionPlan
    confidence: float = Field(ge=0, le=1)


class Capture(StrictModel):
    schema_version: SchemaVersion = "1.0"
    capture_id: str = Field(pattern=r"^cap_[A-Za-z0-9_-]+$")
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    round_index: int = Field(ge=1, le=2)
    media_asset_id: str = Field(pattern=r"^media_[A-Za-z0-9_-]+$")
    status: Literal["uploaded", "processing", "ready", "failed"]
    source_client: Literal["h5", "ios"] | None = None
    capture_method: Literal["photo", "short_video", "photo_fallback"] | None = None
    selected_frame_id: str | None = None
    selected_frame_timestamp_ms: int | None = Field(default=None, ge=0)
    selection_source: Literal["local_recommended", "user_selected"] | None = None
    created_at: datetime


class MediaAsset(StrictModel):
    schema_version: SchemaVersion = "1.0"
    media_asset_id: str = Field(pattern=r"^media_[A-Za-z0-9_-]+$")
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    purpose: Literal["reference", "scene", "capture"]
    content_type: Literal["image/jpeg", "image/png", "image/webp"]
    byte_size: int = Field(ge=1, le=8_000_000)
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    status: Literal["pending_upload", "ready", "failed", "deleted"]
    width: int | None = Field(default=None, ge=1, le=2048)
    height: int | None = Field(default=None, ge=1, le=2048)
    expires_at: datetime
    created_at: datetime


IssueCode = Literal[
    "person_too_large",
    "person_too_small",
    "person_too_left",
    "person_too_right",
    "head_cut",
    "feet_cut",
    "background_blocked",
    "pose_direction_wrong",
    "arm_position_wrong",
    "camera_too_high",
    "camera_too_low",
    "camera_angle_wrong",
    "motion_timing_wrong",
]


class ResultEvaluation(StrictModel):
    schema_version: SchemaVersion = "1.0"
    evaluation_id: str = Field(pattern=r"^eval_[A-Za-z0-9_-]+$")
    capture_id: str = Field(pattern=r"^cap_[A-Za-z0-9_-]+$")
    issue_code: IssueCode | None = None
    top_issue: str | None = Field(default=None, min_length=1, max_length=300)
    next_instruction: str | None = Field(default=None, min_length=1, max_length=160)
    needs_retake: bool
    goal_satisfied: bool
    publish_readiness: float = Field(ge=0, le=1)
    confidence: float = Field(ge=0, le=1)
    execution_mode: Literal["fixture", "live", "fallback"] | None = None

    @model_validator(mode="after")
    def enforce_single_action(self) -> ResultEvaluation:
        if self.goal_satisfied and (self.issue_code is not None or self.needs_retake):
            raise ValueError("satisfied evaluation cannot include an issue or retake")
        if self.needs_retake and (
            self.issue_code is None or self.top_issue is None or self.next_instruction is None
        ):
            raise ValueError("retake evaluation requires exactly one actionable issue")
        return self


class PostJob(StrictModel):
    schema_version: SchemaVersion = "1.0"
    post_id: str = Field(pattern=r"^post_[A-Za-z0-9_-]+$")
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    status: Literal["queued", "rendering", "ready", "failed"]
    output_asset_id: str | None = None
    publish_mode: Literal["preview_only"] = "preview_only"
    created_at: datetime


HandoffStatus = Literal["created", "claimed", "completed", "revoked", "expired"]


class HandoffTask(StrictModel):
    schema_version: SchemaVersion = "1.0"
    handoff_id: str = Field(pattern=r"^handoff_[A-Za-z0-9_-]+$")
    code: str = Field(pattern=r"^\d{6}$")
    status: HandoffStatus
    mode: Literal["original_replication", "scene_adaptation"]
    created_at: datetime
    expires_at: datetime
    claimed_at: datetime | None = None
    completed_at: datetime | None = None


class HandoffRecord(HandoffTask):
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    claimed_client_hash: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")
    claim_token_expires_at: datetime | None = None
    revoked_at: datetime | None = None

    def public_task(self) -> HandoffTask:
        return HandoffTask.model_validate(
            self.model_dump(
                include={
                    "schema_version",
                    "handoff_id",
                    "code",
                    "status",
                    "mode",
                    "created_at",
                    "expires_at",
                    "claimed_at",
                    "completed_at",
                }
            )
        )


class SkillRun(StrictModel):
    schema_version: SchemaVersion = "1.0"
    skill_run_id: str = Field(pattern=r"^skr_[A-Za-z0-9_-]+$")
    skill: SkillRef
    status: Literal["queued", "running", "completed", "failed", "cancelled"]
    latency_ms: int = Field(ge=0)
    estimated_cost_usd: float = Field(ge=0)
    confidence: float = Field(ge=0, le=1)
    fallback_used: bool
    provider: str = Field(min_length=1, max_length=100)
    model: str | None = Field(default=None, max_length=100)
    warnings: list[str] = Field(default_factory=list, max_length=20)
    repair_count: int = Field(default=0, ge=0, le=1)
    error_code: str | None = None


class AgentRun(StrictModel):
    schema_version: SchemaVersion = "1.0"
    run_id: str = Field(pattern=r"^run_[A-Za-z0-9_-]+$")
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    intent: AgentIntent
    selected_skills: list[SkillRef]
    provider: str = Field(min_length=1, max_length=100)
    model: str | None = None
    status: Literal["queued", "running", "completed", "failed", "cancelled"]
    latency_ms: int = Field(ge=0)
    estimated_cost_usd: float = Field(ge=0)
    confidence: float = Field(ge=0, le=1)
    fallback_used: bool
    error_code: str | None = None
    trace_id: str = Field(min_length=1, max_length=128)
    created_at: datetime


class SoloShotSession(StrictModel):
    schema_version: SchemaVersion = "1.0"
    session_id: str = Field(pattern=r"^ss_[A-Za-z0-9_-]+$")
    state: SessionState
    source_channel: Literal["h5_qr", "h5_direct", "ios", "demo_preset", "shared_link"]
    mode: Literal["original_replication", "scene_adaptation"]
    reference_asset: ReferenceAsset | None
    scene_asset_id: str | None = Field(default=None, pattern=r"^media_[A-Za-z0-9_-]+$")
    active_reference_analysis_id: str | None = Field(
        default=None, pattern=r"^ra_[A-Za-z0-9_-]+$"
    )
    user_constraints: UserConstraints
    selected_skills: list[SkillRef]
    shot_plan: ShotPlan | None
    capture_rounds: list[Capture] = Field(max_length=2)
    evaluation: ResultEvaluation | None
    evaluations: list[ResultEvaluation] = Field(default_factory=list, max_length=2)
    external_ai_consent_at: datetime | None = None
    capture_upload_consent_at: datetime | None = None
    publish_package: PostJob | None
    analytics_context: JsonObject
    created_at: datetime
    updated_at: datetime
