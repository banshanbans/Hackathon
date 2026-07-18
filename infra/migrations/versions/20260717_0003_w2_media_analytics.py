"""增加 W2 媒体、参考分析历史和埋点表。"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260717_0003"
down_revision: str | Sequence[str] | None = "20260717_0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

jsonb = postgresql.JSONB(astext_type=sa.Text())


def upgrade() -> None:
    op.create_table(
        "reference_analyses",
        sa.Column("analysis_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "reference_id",
            sa.String(length=80),
            sa.ForeignKey("reference_assets.reference_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("analysis_kind", sa.String(length=20), nullable=False),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_table(
        "media_assets",
        sa.Column("media_asset_id", sa.String(length=80), primary_key=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("object_key", sa.String(length=255), nullable=False, unique=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_index("ix_media_assets_expires_at", "media_assets", ["expires_at"])
    op.create_table(
        "analytics_events",
        sa.Column("event_id", sa.String(length=36), primary_key=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("event_name", sa.String(length=64), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_index(
        "ix_analytics_events_session_name",
        "analytics_events",
        ["session_id", "event_name"],
    )


def downgrade() -> None:
    op.drop_index("ix_analytics_events_session_name", table_name="analytics_events")
    op.drop_table("analytics_events")
    op.drop_index("ix_media_assets_expires_at", table_name="media_assets")
    op.drop_table("media_assets")
    op.drop_table("reference_analyses")
