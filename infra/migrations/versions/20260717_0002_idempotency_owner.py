"""将幂等记录绑定到 Session，以便删除时级联清理。"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260717_0002"
down_revision: str | Sequence[str] | None = "20260717_0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "idempotency_records",
        sa.Column("owner_session_id", sa.String(length=80), nullable=True),
    )
    op.create_foreign_key(
        "fk_idempotency_records_owner_session",
        "idempotency_records",
        "sessions",
        ["owner_session_id"],
        ["session_id"],
        ondelete="CASCADE",
    )


def downgrade() -> None:
    op.drop_constraint(
        "fk_idempotency_records_owner_session",
        "idempotency_records",
        type_="foreignkey",
    )
    op.drop_column("idempotency_records", "owner_session_id")
