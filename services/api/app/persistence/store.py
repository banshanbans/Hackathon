from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from app.domain.models import JsonObject


@dataclass(frozen=True)
class IdempotencyRecord:
    fingerprint: str
    status_code: int
    data: JsonObject
    execution_mode: str | None
    owner_session_id: str | None


@dataclass(frozen=True)
class MediaRecord:
    asset: JsonObject
    object_key: str


class StateStore(Protocol):
    def transaction(self) -> AbstractAsyncContextManager[None]: ...
    async def get_session(self, session_id: str) -> JsonObject | None: ...
    async def put_session(self, session_id: str, payload: JsonObject) -> None: ...
    async def delete_session(self, session_id: str) -> bool: ...
    async def put_reference(
        self, reference_id: str, session_id: str, asset: JsonObject, analysis: JsonObject
    ) -> None: ...
    async def get_reference(self, reference_id: str) -> JsonObject | None: ...
    async def get_analysis_for_session(self, session_id: str) -> JsonObject | None: ...
    async def put_reference_analysis(
        self,
        reference_id: str,
        session_id: str,
        analysis: JsonObject,
        analysis_kind: str,
    ) -> None: ...
    async def put_shot_plan(self, plan_id: str, session_id: str, payload: JsonObject) -> None: ...
    async def put_agent_run(self, run_id: str, session_id: str, payload: JsonObject) -> None: ...
    async def get_agent_run(self, run_id: str) -> JsonObject | None: ...
    async def put_skill_run(
        self,
        skill_run_id: str,
        run_id: str | None,
        session_id: str,
        position: int,
        payload: JsonObject,
        output: JsonObject,
    ) -> None: ...
    async def get_skill_runs(self, run_id: str) -> list[JsonObject]: ...
    async def put_capture(self, capture_id: str, session_id: str, payload: JsonObject) -> None: ...
    async def get_capture(self, capture_id: str) -> JsonObject | None: ...
    async def put_evaluation(
        self, evaluation_id: str, session_id: str, capture_id: str, payload: JsonObject
    ) -> None: ...
    async def put_media(
        self, media_asset_id: str, session_id: str, asset: JsonObject, object_key: str
    ) -> None: ...
    async def get_media(self, media_asset_id: str) -> MediaRecord | None: ...
    async def list_media_for_session(self, session_id: str) -> list[MediaRecord]: ...
    async def list_expired_media(self, before: datetime) -> list[MediaRecord]: ...
    async def delete_media(self, media_asset_id: str) -> None: ...
    async def put_events(self, events: list[JsonObject]) -> tuple[int, int]: ...
    async def get_handoff(self, code: str) -> JsonObject | None: ...
    async def get_latest_handoff_for_session(self, session_id: str) -> JsonObject | None: ...
    async def list_unclaimed_handoffs(
        self, after: datetime, limit: int
    ) -> list[JsonObject]: ...
    async def put_handoff(self, payload: JsonObject) -> None: ...
    async def list_expired_handoffs(self, before: datetime) -> list[JsonObject]: ...
    async def put_post(self, post_id: str, session_id: str, payload: JsonObject) -> None: ...
    async def get_post(self, post_id: str) -> JsonObject | None: ...
    async def get_idempotency(self, operation: str, key: str) -> IdempotencyRecord | None: ...
    async def put_idempotency(
        self, operation: str, key: str, record: IdempotencyRecord
    ) -> None: ...


class MemoryStateStore:
    def __init__(self) -> None:
        self.sessions: dict[str, JsonObject] = {}
        self.references: dict[tuple[str, str], tuple[str, JsonObject, JsonObject]] = {}
        self.analyses: dict[str, JsonObject] = {}
        self.analysis_history: dict[str, list[JsonObject]] = {}
        self.shot_plans: dict[str, JsonObject] = {}
        self.agent_runs: dict[str, JsonObject] = {}
        self.skill_runs: dict[str, list[tuple[int, JsonObject]]] = {}
        self.captures: dict[str, JsonObject] = {}
        self.evaluations: dict[str, JsonObject] = {}
        self.posts: dict[str, JsonObject] = {}
        self.media: dict[str, MediaRecord] = {}
        self.events: dict[str, JsonObject] = {}
        self.handoffs: dict[str, JsonObject] = {}
        self.idempotency: dict[tuple[str, str], IdempotencyRecord] = {}
        self._transaction_lock = asyncio.Lock()
        self._inside_transaction: ContextVar[bool] = ContextVar(
            "soloshot_memory_transaction", default=False
        )

    @asynccontextmanager
    async def transaction(self) -> AsyncIterator[None]:
        if self._inside_transaction.get():
            yield
            return
        async with self._transaction_lock:
            token = self._inside_transaction.set(True)
            try:
                yield
            finally:
                self._inside_transaction.reset(token)

    async def get_session(self, session_id: str) -> JsonObject | None:
        return self.sessions.get(session_id)

    async def put_session(self, session_id: str, payload: JsonObject) -> None:
        self.sessions[session_id] = payload

    async def delete_session(self, session_id: str) -> bool:
        if self.sessions.pop(session_id, None) is None:
            return False
        reference_keys = [key for key, value in self.references.items() if value[0] == session_id]
        for reference_key in reference_keys:
            self.references.pop(reference_key, None)
        self.analyses.pop(session_id, None)
        self.analysis_history.pop(session_id, None)
        self.shot_plans = {
            key: value
            for key, value in self.shot_plans.items()
            if value.get("session_id") != session_id
        }
        run_ids = [
            key for key, value in self.agent_runs.items() if value["session_id"] == session_id
        ]
        for run_id in run_ids:
            self.agent_runs.pop(run_id, None)
            self.skill_runs.pop(run_id, None)
        self.captures = {
            key: value for key, value in self.captures.items() if value["session_id"] != session_id
        }
        self.posts = {
            key: value for key, value in self.posts.items() if value["session_id"] != session_id
        }
        self.evaluations = {
            key: value
            for key, value in self.evaluations.items()
            if value.get("_owner_session_id") != session_id
        }
        self.idempotency = {
            key: value
            for key, value in self.idempotency.items()
            if value.owner_session_id != session_id
        }
        self.media = {
            key: value
            for key, value in self.media.items()
            if value.asset.get("session_id") != session_id
        }
        self.events = {
            key: value
            for key, value in self.events.items()
            if value.get("session_id") != session_id
        }
        self.handoffs = {
            key: value
            for key, value in self.handoffs.items()
            if value.get("session_id") != session_id
        }
        return True

    async def put_reference(
        self, reference_id: str, session_id: str, asset: JsonObject, analysis: JsonObject
    ) -> None:
        for existing_key, value in list(self.references.items()):
            if value[0] == session_id:
                self.references.pop(existing_key)
        self.references[(reference_id, session_id)] = (session_id, asset, analysis)
        self.analyses[session_id] = analysis
        self.analysis_history.setdefault(session_id, []).append(
            {**analysis, "analysis_kind": "original"}
        )

    async def get_reference(self, reference_id: str) -> JsonObject | None:
        item = next(
            (
                value
                for (stored_id, _), value in self.references.items()
                if stored_id == reference_id
            ),
            None,
        )
        return None if item is None else item[1]

    async def get_analysis_for_session(self, session_id: str) -> JsonObject | None:
        return self.analyses.get(session_id)

    async def put_reference_analysis(
        self,
        reference_id: str,
        session_id: str,
        analysis: JsonObject,
        analysis_kind: str,
    ) -> None:
        key = (reference_id, session_id)
        reference = self.references.get(key)
        if reference is None:
            return
        self.references[key] = (session_id, reference[1], analysis)
        self.analyses[session_id] = analysis
        self.analysis_history.setdefault(session_id, []).append(
            {**analysis, "analysis_kind": analysis_kind}
        )

    async def put_shot_plan(self, plan_id: str, session_id: str, payload: JsonObject) -> None:
        self.shot_plans[plan_id] = {**payload, "session_id": session_id}

    async def put_agent_run(self, run_id: str, session_id: str, payload: JsonObject) -> None:
        self.agent_runs[run_id] = payload

    async def get_agent_run(self, run_id: str) -> JsonObject | None:
        return self.agent_runs.get(run_id)

    async def put_skill_run(
        self,
        skill_run_id: str,
        run_id: str | None,
        session_id: str,
        position: int,
        payload: JsonObject,
        output: JsonObject,
    ) -> None:
        if run_id is not None:
            self.skill_runs.setdefault(run_id, []).append((position, payload))

    async def get_skill_runs(self, run_id: str) -> list[JsonObject]:
        return [payload for _, payload in sorted(self.skill_runs.get(run_id, []))]

    async def put_capture(self, capture_id: str, session_id: str, payload: JsonObject) -> None:
        self.captures[capture_id] = payload

    async def get_capture(self, capture_id: str) -> JsonObject | None:
        return self.captures.get(capture_id)

    async def put_evaluation(
        self, evaluation_id: str, session_id: str, capture_id: str, payload: JsonObject
    ) -> None:
        self.evaluations[evaluation_id] = {**payload, "_owner_session_id": session_id}

    async def put_media(
        self, media_asset_id: str, session_id: str, asset: JsonObject, object_key: str
    ) -> None:
        self.media[media_asset_id] = MediaRecord(asset=asset, object_key=object_key)

    async def get_media(self, media_asset_id: str) -> MediaRecord | None:
        return self.media.get(media_asset_id)

    async def list_media_for_session(self, session_id: str) -> list[MediaRecord]:
        return [
            value for value in self.media.values() if value.asset.get("session_id") == session_id
        ]

    async def list_expired_media(self, before: datetime) -> list[MediaRecord]:
        result: list[MediaRecord] = []
        for value in self.media.values():
            expires_at = value.asset.get("expires_at")
            if isinstance(expires_at, str) and datetime.fromisoformat(expires_at) <= before:
                result.append(value)
        return result

    async def delete_media(self, media_asset_id: str) -> None:
        self.media.pop(media_asset_id, None)

    async def put_events(self, events: list[JsonObject]) -> tuple[int, int]:
        accepted = 0
        duplicates = 0
        for event in events:
            event_id = event.get("event_id")
            if not isinstance(event_id, str):
                continue
            if event_id in self.events:
                duplicates += 1
            else:
                self.events[event_id] = event
                accepted += 1
        return accepted, duplicates

    async def get_handoff(self, code: str) -> JsonObject | None:
        return self.handoffs.get(code)

    async def get_latest_handoff_for_session(self, session_id: str) -> JsonObject | None:
        matches = [
            value for value in self.handoffs.values() if value.get("session_id") == session_id
        ]
        if not matches:
            return None
        return max(matches, key=lambda item: str(item.get("created_at", "")))

    async def put_handoff(self, payload: JsonObject) -> None:
        self.handoffs[str(payload["code"])] = payload

    async def list_unclaimed_handoffs(
        self, after: datetime, limit: int
    ) -> list[JsonObject]:
        result = [
            value
            for value in self.handoffs.values()
            if value.get("status") == "created"
            and isinstance(value.get("expires_at"), str)
            and datetime.fromisoformat(str(value["expires_at"])) > after
        ]
        result.sort(key=lambda item: str(item.get("created_at", "")), reverse=True)
        return result[:limit]

    async def list_expired_handoffs(self, before: datetime) -> list[JsonObject]:
        result: list[JsonObject] = []
        for value in self.handoffs.values():
            expires_at = value.get("expires_at")
            if (
                value.get("status") in {"created", "claimed"}
                and isinstance(expires_at, str)
                and datetime.fromisoformat(expires_at) <= before
            ):
                result.append(value)
        return result

    async def put_post(self, post_id: str, session_id: str, payload: JsonObject) -> None:
        self.posts[post_id] = payload

    async def get_post(self, post_id: str) -> JsonObject | None:
        return self.posts.get(post_id)

    async def get_idempotency(self, operation: str, key: str) -> IdempotencyRecord | None:
        return self.idempotency.get((operation, key))

    async def put_idempotency(self, operation: str, key: str, record: IdempotencyRecord) -> None:
        self.idempotency[(operation, key)] = record
