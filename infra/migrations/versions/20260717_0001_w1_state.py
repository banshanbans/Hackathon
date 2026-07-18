"""创建 W1 Agent/Skill 持久化表。"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260717_0001"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

jsonb = postgresql.JSONB(astext_type=sa.Text())


def upgrade() -> None:
    op.create_table(
        "sessions",
        sa.Column("session_id", sa.String(length=80), primary_key=True),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_table(
        "reference_assets",
        sa.Column("reference_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("asset", jsonb, nullable=False),
        sa.Column("analysis", jsonb, nullable=False),
        sa.UniqueConstraint("session_id", name="uq_reference_assets_session"),
    )
    op.create_table(
        "shot_plans",
        sa.Column("plan_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_table(
        "agent_runs",
        sa.Column("run_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_table(
        "skill_runs",
        sa.Column("skill_run_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "run_id",
            sa.String(length=80),
            sa.ForeignKey("agent_runs.run_id", ondelete="CASCADE"),
            nullable=True,
        ),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("payload", jsonb, nullable=False),
        sa.Column("output", jsonb, nullable=False),
    )
    op.create_table(
        "captures",
        sa.Column("capture_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_table(
        "evaluations",
        sa.Column("evaluation_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "capture_id",
            sa.String(length=80),
            sa.ForeignKey("captures.capture_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_table(
        "posts",
        sa.Column("post_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_table(
        "idempotency_records",
        sa.Column("operation", sa.String(length=120), primary_key=True),
        sa.Column("idempotency_key", sa.String(length=128), primary_key=True),
        sa.Column("fingerprint", sa.String(length=64), nullable=False),
        sa.Column("status_code", sa.Integer(), nullable=False),
        sa.Column("data", jsonb, nullable=False),
        sa.Column("execution_mode", sa.String(length=20), nullable=True),
    )


def downgrade() -> None:
    for table in (
        "idempotency_records",
        "posts",
        "evaluations",
        "captures",
        "skill_runs",
        "agent_runs",
        "shot_plans",
        "reference_assets",
        "sessions",
    ):
        op.drop_table(table)
