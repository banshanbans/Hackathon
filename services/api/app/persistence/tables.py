from sqlalchemy import (
    JSON,
    Column,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Integer,
    MetaData,
    String,
    Table,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB

metadata = MetaData()
json_type = JSON().with_variant(JSONB(), "postgresql")

sessions = Table(
    "sessions",
    metadata,
    Column("session_id", String(80), primary_key=True),
    Column("payload", json_type, nullable=False),
)

references = Table(
    "reference_assets",
    metadata,
    Column("reference_id", String(80), primary_key=True),
    Column(
        "session_id",
        String(80),
        ForeignKey("sessions.session_id", ondelete="CASCADE"),
        primary_key=True,
    ),
    Column("asset", json_type, nullable=False),
    Column("analysis", json_type, nullable=False),
    UniqueConstraint("session_id", name="uq_reference_assets_session"),
)

reference_analyses = Table(
    "reference_analyses",
    metadata,
    Column("analysis_id", String(80), primary_key=True),
    Column("reference_id", String(80), nullable=False),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("analysis_kind", String(20), nullable=False),
    Column("payload", json_type, nullable=False),
    ForeignKeyConstraint(
        ["reference_id", "session_id"],
        ["reference_assets.reference_id", "reference_assets.session_id"],
        name="fk_reference_analyses_reference_session",
        ondelete="CASCADE",
    ),
)

shot_plans = Table(
    "shot_plans",
    metadata,
    Column("plan_id", String(80), primary_key=True),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("payload", json_type, nullable=False),
)

agent_runs = Table(
    "agent_runs",
    metadata,
    Column("run_id", String(80), primary_key=True),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("payload", json_type, nullable=False),
)

skill_runs = Table(
    "skill_runs",
    metadata,
    Column("skill_run_id", String(80), primary_key=True),
    Column("run_id", String(80), ForeignKey("agent_runs.run_id", ondelete="CASCADE")),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("position", Integer, nullable=False),
    Column("payload", json_type, nullable=False),
    Column("output", json_type, nullable=False),
)

captures = Table(
    "captures",
    metadata,
    Column("capture_id", String(80), primary_key=True),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("payload", json_type, nullable=False),
    UniqueConstraint("session_id", "capture_id", name="uq_captures_session_capture"),
)

evaluations = Table(
    "evaluations",
    metadata,
    Column("evaluation_id", String(80), primary_key=True),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("capture_id", String(80), ForeignKey("captures.capture_id", ondelete="CASCADE")),
    Column("payload", json_type, nullable=False),
)

media_assets = Table(
    "media_assets",
    metadata,
    Column("media_asset_id", String(80), primary_key=True),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("object_key", String(255), nullable=False, unique=True),
    Column("expires_at", DateTime(timezone=True), nullable=False),
    Column("payload", json_type, nullable=False),
)

analytics_events = Table(
    "analytics_events",
    metadata,
    Column("event_id", String(36), primary_key=True),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("event_name", String(64), nullable=False),
    Column("occurred_at", DateTime(timezone=True), nullable=False),
    Column("payload", json_type, nullable=False),
)

handoffs = Table(
    "handoffs",
    metadata,
    Column("handoff_id", String(80), primary_key=True),
    Column("code", String(6), nullable=False, unique=True),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("status", String(20), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False),
    Column("expires_at", DateTime(timezone=True), nullable=False),
    Column("payload", json_type, nullable=False),
)

posts = Table(
    "posts",
    metadata,
    Column("post_id", String(80), primary_key=True),
    Column("session_id", String(80), ForeignKey("sessions.session_id", ondelete="CASCADE")),
    Column("payload", json_type, nullable=False),
)

idempotency_records = Table(
    "idempotency_records",
    metadata,
    Column("operation", String(120), primary_key=True),
    Column("idempotency_key", String(128), primary_key=True),
    Column(
        "owner_session_id",
        String(80),
        ForeignKey("sessions.session_id", ondelete="CASCADE"),
    ),
    Column("fingerprint", String(64), nullable=False),
    Column("status_code", Integer, nullable=False),
    Column("data", json_type, nullable=False),
    Column("execution_mode", String(20)),
)
