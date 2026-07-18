from __future__ import annotations

from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from contextvars import ContextVar
from datetime import datetime
from typing import Any

from sqlalchemy import delete, select, text, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from app.domain.models import JsonObject
from app.persistence.store import IdempotencyRecord, MediaRecord
from app.persistence.tables import (
    agent_runs,
    analytics_events,
    captures,
    evaluations,
    handoffs,
    idempotency_records,
    media_assets,
    posts,
    reference_analyses,
    references,
    sessions,
    shot_plans,
    skill_runs,
)


def _json(value: Mapping[str, Any]) -> JsonObject:
    return dict(value)


class PostgresStateStore:
    def __init__(self, database_url: str) -> None:
        async_url = database_url.replace("postgresql://", "postgresql+asyncpg://", 1)
        self.engine: AsyncEngine = create_async_engine(async_url, pool_pre_ping=True)
        self._active_connection: ContextVar[AsyncConnection | None] = ContextVar(
            "soloshot_w1_connection", default=None
        )

    @asynccontextmanager
    async def transaction(self) -> AsyncIterator[None]:
        existing = self._active_connection.get()
        if existing is not None:
            yield
            return
        async with self.engine.begin() as connection:
            token = self._active_connection.set(connection)
            try:
                yield
            finally:
                self._active_connection.reset(token)

    @asynccontextmanager
    async def _connection(self, *, write: bool = False) -> AsyncIterator[AsyncConnection]:
        existing = self._active_connection.get()
        if existing is not None:
            yield existing
            return
        if write:
            async with self.engine.begin() as connection:
                yield connection
        else:
            async with self.engine.connect() as connection:
                yield connection

    async def close(self) -> None:
        await self.engine.dispose()

    async def get_session(self, session_id: str) -> JsonObject | None:
        statement = select(sessions.c.payload).where(sessions.c.session_id == session_id)
        if self._active_connection.get() is not None:
            statement = statement.with_for_update()
        async with self._connection() as connection:
            value = await connection.scalar(statement)
        return None if value is None else _json(value)

    async def put_session(self, session_id: str, payload: JsonObject) -> None:
        statement = insert(sessions).values(session_id=session_id, payload=payload)
        statement = statement.on_conflict_do_update(
            index_elements=[sessions.c.session_id], set_={"payload": statement.excluded.payload}
        )
        async with self._connection(write=True) as connection:
            await connection.execute(statement)

    async def delete_session(self, session_id: str) -> bool:
        async with self._connection(write=True) as connection:
            result = await connection.execute(
                delete(sessions).where(sessions.c.session_id == session_id)
            )
        return bool(result.rowcount)

    async def put_reference(
        self, reference_id: str, session_id: str, asset: JsonObject, analysis: JsonObject
    ) -> None:
        statement = insert(references).values(
            reference_id=reference_id, session_id=session_id, asset=asset, analysis=analysis
        )
        async with self._connection(write=True) as connection:
            await connection.execute(
                delete(references).where(references.c.session_id == session_id)
            )
            await connection.execute(statement)
            await connection.execute(
                insert(reference_analyses).values(
                    analysis_id=analysis["analysis_id"],
                    reference_id=reference_id,
                    session_id=session_id,
                    analysis_kind="original",
                    payload=analysis,
                )
            )

    async def get_reference(self, reference_id: str) -> JsonObject | None:
        async with self._connection() as connection:
            value = await connection.scalar(
                select(references.c.asset).where(references.c.reference_id == reference_id)
            )
        return None if value is None else _json(value)

    async def get_analysis_for_session(self, session_id: str) -> JsonObject | None:
        async with self._connection() as connection:
            value = await connection.scalar(
                select(references.c.analysis).where(references.c.session_id == session_id)
            )
        return None if value is None else _json(value)

    async def put_reference_analysis(
        self,
        reference_id: str,
        session_id: str,
        analysis: JsonObject,
        analysis_kind: str,
    ) -> None:
        async with self._connection(write=True) as connection:
            await connection.execute(
                insert(reference_analyses).values(
                    analysis_id=analysis["analysis_id"],
                    reference_id=reference_id,
                    session_id=session_id,
                    analysis_kind=analysis_kind,
                    payload=analysis,
                )
            )
            await connection.execute(
                update(references)
                .where(
                    references.c.reference_id == reference_id,
                    references.c.session_id == session_id,
                )
                .values(analysis=analysis)
            )

    async def put_shot_plan(self, plan_id: str, session_id: str, payload: JsonObject) -> None:
        statement = insert(shot_plans).values(
            plan_id=plan_id, session_id=session_id, payload=payload
        )
        statement = statement.on_conflict_do_update(
            index_elements=[shot_plans.c.plan_id], set_={"payload": statement.excluded.payload}
        )
        async with self._connection(write=True) as connection:
            await connection.execute(statement)

    async def put_agent_run(self, run_id: str, session_id: str, payload: JsonObject) -> None:
        statement = insert(agent_runs).values(run_id=run_id, session_id=session_id, payload=payload)
        statement = statement.on_conflict_do_update(
            index_elements=[agent_runs.c.run_id], set_={"payload": statement.excluded.payload}
        )
        async with self._connection(write=True) as connection:
            await connection.execute(statement)

    async def get_agent_run(self, run_id: str) -> JsonObject | None:
        async with self._connection() as connection:
            value = await connection.scalar(
                select(agent_runs.c.payload).where(agent_runs.c.run_id == run_id)
            )
        return None if value is None else _json(value)

    async def put_skill_run(
        self,
        skill_run_id: str,
        run_id: str | None,
        session_id: str,
        position: int,
        payload: JsonObject,
        output: JsonObject,
    ) -> None:
        statement = insert(skill_runs).values(
            skill_run_id=skill_run_id,
            run_id=run_id,
            session_id=session_id,
            position=position,
            payload=payload,
            output=output,
        )
        statement = statement.on_conflict_do_update(
            index_elements=[skill_runs.c.skill_run_id],
            set_={"payload": statement.excluded.payload, "output": statement.excluded.output},
        )
        async with self._connection(write=True) as connection:
            await connection.execute(statement)

    async def get_skill_runs(self, run_id: str) -> list[JsonObject]:
        async with self._connection() as connection:
            rows = (
                await connection.execute(
                    select(skill_runs.c.payload)
                    .where(skill_runs.c.run_id == run_id)
                    .order_by(skill_runs.c.position)
                )
            ).scalars()
            return [_json(value) for value in rows]

    async def put_capture(self, capture_id: str, session_id: str, payload: JsonObject) -> None:
        statement = insert(captures).values(
            capture_id=capture_id, session_id=session_id, payload=payload
        )
        statement = statement.on_conflict_do_update(
            index_elements=[captures.c.capture_id], set_={"payload": statement.excluded.payload}
        )
        async with self._connection(write=True) as connection:
            await connection.execute(statement)

    async def get_capture(self, capture_id: str) -> JsonObject | None:
        async with self._connection() as connection:
            value = await connection.scalar(
                select(captures.c.payload).where(captures.c.capture_id == capture_id)
            )
        return None if value is None else _json(value)

    async def put_evaluation(
        self, evaluation_id: str, session_id: str, capture_id: str, payload: JsonObject
    ) -> None:
        async with self._connection(write=True) as connection:
            await connection.execute(
                insert(evaluations).values(
                    evaluation_id=evaluation_id,
                    session_id=session_id,
                    capture_id=capture_id,
                    payload=payload,
                )
            )

    async def put_media(
        self, media_asset_id: str, session_id: str, asset: JsonObject, object_key: str
    ) -> None:
        expires_at = datetime.fromisoformat(str(asset["expires_at"]))
        statement = insert(media_assets).values(
            media_asset_id=media_asset_id,
            session_id=session_id,
            object_key=object_key,
            expires_at=expires_at,
            payload=asset,
        )
        statement = statement.on_conflict_do_update(
            index_elements=[media_assets.c.media_asset_id],
            set_={
                "payload": statement.excluded.payload,
                "expires_at": statement.excluded.expires_at,
            },
        )
        async with self._connection(write=True) as connection:
            await connection.execute(statement)

    async def get_media(self, media_asset_id: str) -> MediaRecord | None:
        async with self._connection() as connection:
            row = (
                (
                    await connection.execute(
                        select(media_assets.c.payload, media_assets.c.object_key).where(
                            media_assets.c.media_asset_id == media_asset_id
                        )
                    )
                )
                .mappings()
                .first()
            )
        if row is None:
            return None
        return MediaRecord(asset=_json(row["payload"]), object_key=str(row["object_key"]))

    async def list_media_for_session(self, session_id: str) -> list[MediaRecord]:
        async with self._connection() as connection:
            rows = (
                await connection.execute(
                    select(media_assets.c.payload, media_assets.c.object_key).where(
                        media_assets.c.session_id == session_id
                    )
                )
            ).mappings()
        return [
            MediaRecord(asset=_json(row["payload"]), object_key=str(row["object_key"]))
            for row in rows
        ]

    async def list_expired_media(self, before: datetime) -> list[MediaRecord]:
        async with self._connection() as connection:
            rows = (
                await connection.execute(
                    select(media_assets.c.payload, media_assets.c.object_key).where(
                        media_assets.c.expires_at <= before
                    )
                )
            ).mappings()
        return [
            MediaRecord(asset=_json(row["payload"]), object_key=str(row["object_key"]))
            for row in rows
        ]

    async def delete_media(self, media_asset_id: str) -> None:
        async with self._connection(write=True) as connection:
            await connection.execute(
                delete(media_assets).where(media_assets.c.media_asset_id == media_asset_id)
            )

    async def put_events(self, events: list[JsonObject]) -> tuple[int, int]:
        accepted = 0
        duplicates = 0
        async with self._connection(write=True) as connection:
            for event in events:
                statement = (
                    insert(analytics_events)
                    .values(
                        event_id=event["event_id"],
                        session_id=event["session_id"],
                        event_name=event["event_name"],
                        occurred_at=datetime.fromisoformat(str(event["timestamp"])),
                        payload=event,
                    )
                    .on_conflict_do_nothing(index_elements=[analytics_events.c.event_id])
                )
                result = await connection.execute(statement)
                if result.rowcount:
                    accepted += 1
                else:
                    duplicates += 1
        return accepted, duplicates

    async def get_handoff(self, code: str) -> JsonObject | None:
        statement = select(handoffs.c.payload).where(handoffs.c.code == code)
        if self._active_connection.get() is not None:
            statement = statement.with_for_update()
        async with self._connection() as connection:
            value = await connection.scalar(statement)
        return None if value is None else _json(value)

    async def get_latest_handoff_for_session(self, session_id: str) -> JsonObject | None:
        statement = (
            select(handoffs.c.payload)
            .where(handoffs.c.session_id == session_id)
            .order_by(handoffs.c.created_at.desc())
            .limit(1)
        )
        if self._active_connection.get() is not None:
            statement = statement.with_for_update()
        async with self._connection() as connection:
            value = await connection.scalar(statement)
        return None if value is None else _json(value)

    async def put_handoff(self, payload: JsonObject) -> None:
        statement = insert(handoffs).values(
            handoff_id=payload["handoff_id"],
            code=payload["code"],
            session_id=payload["session_id"],
            status=payload["status"],
            created_at=datetime.fromisoformat(str(payload["created_at"])),
            expires_at=datetime.fromisoformat(str(payload["expires_at"])),
            payload=payload,
        )
        statement = statement.on_conflict_do_update(
            index_elements=[handoffs.c.handoff_id],
            set_={
                "status": statement.excluded.status,
                "expires_at": statement.excluded.expires_at,
                "payload": statement.excluded.payload,
            },
        )
        async with self._connection(write=True) as connection:
            await connection.execute(statement)

    async def list_expired_handoffs(self, before: datetime) -> list[JsonObject]:
        async with self._connection() as connection:
            values = (
                await connection.execute(
                    select(handoffs.c.payload).where(
                        handoffs.c.status.in_(["created", "claimed"]),
                        handoffs.c.expires_at <= before,
                    )
                )
            ).scalars()
            return [_json(value) for value in values]

    async def put_post(self, post_id: str, session_id: str, payload: JsonObject) -> None:
        statement = insert(posts).values(post_id=post_id, session_id=session_id, payload=payload)
        statement = statement.on_conflict_do_update(
            index_elements=[posts.c.post_id], set_={"payload": statement.excluded.payload}
        )
        async with self._connection(write=True) as connection:
            await connection.execute(statement)

    async def get_post(self, post_id: str) -> JsonObject | None:
        async with self._connection() as connection:
            value = await connection.scalar(
                select(posts.c.payload).where(posts.c.post_id == post_id)
            )
        return None if value is None else _json(value)

    async def get_idempotency(self, operation: str, key: str) -> IdempotencyRecord | None:
        async with self._connection() as connection:
            await connection.execute(
                text("SELECT pg_advisory_xact_lock(hashtextextended(:lock_key, 0))"),
                {"lock_key": f"{operation}:{key}"},
            )
            row = (
                (
                    await connection.execute(
                        select(idempotency_records).where(
                            idempotency_records.c.operation == operation,
                            idempotency_records.c.idempotency_key == key,
                        )
                    )
                )
                .mappings()
                .first()
            )
        if row is None:
            return None
        return IdempotencyRecord(
            fingerprint=row["fingerprint"],
            status_code=row["status_code"],
            data=_json(row["data"]),
            execution_mode=row["execution_mode"],
            owner_session_id=row["owner_session_id"],
        )

    async def put_idempotency(self, operation: str, key: str, record: IdempotencyRecord) -> None:
        statement = insert(idempotency_records).values(
            operation=operation,
            idempotency_key=key,
            owner_session_id=record.owner_session_id,
            fingerprint=record.fingerprint,
            status_code=record.status_code,
            data=record.data,
            execution_mode=record.execution_mode,
        )
        statement = statement.on_conflict_do_nothing()
        async with self._connection(write=True) as connection:
            await connection.execute(statement)
