"""增加 W3 跨端任务接力表。"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260718_0005"
down_revision: str | Sequence[str] | None = "20260717_0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

jsonb = postgresql.JSONB(astext_type=sa.Text())


def upgrade() -> None:
    op.create_table(
        "handoffs",
        sa.Column("handoff_id", sa.String(length=80), primary_key=True),
        sa.Column("code", sa.String(length=6), nullable=False, unique=True),
        sa.Column(
            "session_id",
            sa.String(length=80),
            sa.ForeignKey("sessions.session_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("status", sa.String(length=20), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("payload", jsonb, nullable=False),
    )
    op.create_index("ix_handoffs_session_created", "handoffs", ["session_id", "created_at"])
    op.create_index("ix_handoffs_status_expires", "handoffs", ["status", "expires_at"])


def downgrade() -> None:
    op.drop_index("ix_handoffs_status_expires", table_name="handoffs")
    op.drop_index("ix_handoffs_session_created", table_name="handoffs")
    op.drop_table("handoffs")
