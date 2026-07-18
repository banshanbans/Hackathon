"""允许同一预设参考被多个 Session 安全复用。"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260717_0004"
down_revision: str | Sequence[str] | None = "20260717_0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint(
        "reference_analyses_reference_id_fkey",
        "reference_analyses",
        type_="foreignkey",
    )
    op.drop_constraint("reference_assets_pkey", "reference_assets", type_="primary")
    op.create_primary_key(
        "pk_reference_assets",
        "reference_assets",
        ["reference_id", "session_id"],
    )
    op.create_index(
        "ix_reference_assets_reference_id",
        "reference_assets",
        ["reference_id"],
    )
    op.create_foreign_key(
        "fk_reference_analyses_reference_session",
        "reference_analyses",
        "reference_assets",
        ["reference_id", "session_id"],
        ["reference_id", "session_id"],
        ondelete="CASCADE",
    )


def downgrade() -> None:
    connection = op.get_bind()
    duplicate = connection.execute(
        sa.text(
            """
            SELECT reference_id
            FROM reference_assets
            GROUP BY reference_id
            HAVING count(*) > 1
            LIMIT 1
            """
        )
    ).scalar()
    if duplicate is not None:
        raise RuntimeError(
            "无法恢复全局 reference_id 主键；请先删除重复预设的测试 Session。"
        )
    op.drop_constraint(
        "fk_reference_analyses_reference_session",
        "reference_analyses",
        type_="foreignkey",
    )
    op.drop_index("ix_reference_assets_reference_id", table_name="reference_assets")
    op.drop_constraint("pk_reference_assets", "reference_assets", type_="primary")
    op.create_primary_key("reference_assets_pkey", "reference_assets", ["reference_id"])
    op.create_foreign_key(
        "reference_analyses_reference_id_fkey",
        "reference_analyses",
        "reference_assets",
        ["reference_id"],
        ["reference_id"],
        ondelete="CASCADE",
    )
