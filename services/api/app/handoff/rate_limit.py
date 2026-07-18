from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import dataclass
from typing import Protocol

from app.domain.errors import DomainError


class HandoffRateLimiter(Protocol):
    async def consume(self, scope: str, identity: str, limit: int) -> None: ...

    async def aclose(self) -> None: ...


@dataclass
class _Window:
    started_at: float
    count: int


class MemoryHandoffRateLimiter:
    def __init__(self, window_seconds: int = 60) -> None:
        self.window_seconds = window_seconds
        self._windows: dict[tuple[str, str], _Window] = {}
        self._lock = asyncio.Lock()

    async def consume(self, scope: str, identity: str, limit: int) -> None:
        digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
        key = (scope, digest)
        now = time.monotonic()
        async with self._lock:
            window = self._windows.get(key)
            if window is None or now - window.started_at >= self.window_seconds:
                self._windows[key] = _Window(started_at=now, count=1)
                return
            if window.count >= limit:
                retry_after = max(1, int(self.window_seconds - (now - window.started_at)))
                raise DomainError(
                    "HANDOFF_RATE_LIMITED",
                    "Too many handoff attempts; retry later",
                    status_code=429,
                    recoverable=True,
                    retry_after=retry_after,
                )
            window.count += 1

    async def aclose(self) -> None:
        return None


class RedisHandoffRateLimiter:
    def __init__(self, redis_url: str, window_seconds: int = 60) -> None:
        from redis.asyncio import Redis

        self.window_seconds = window_seconds
        self._redis = Redis.from_url(redis_url, decode_responses=True)

    async def consume(self, scope: str, identity: str, limit: int) -> None:
        digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
        window = int(time.time() // self.window_seconds)
        key = f"soloshot:handoff:{scope}:{digest}:{window}"
        try:
            async with self._redis.pipeline(transaction=True) as pipeline:
                pipeline.incr(key)
                pipeline.expire(key, self.window_seconds + 1)
                count, _ = await pipeline.execute()
        except Exception as error:
            raise DomainError(
                "INTERNAL_ERROR",
                "Handoff protection is temporarily unavailable",
                status_code=503,
                recoverable=True,
                retry_after=5,
            ) from error
        if int(count) > limit:
            raise DomainError(
                "HANDOFF_RATE_LIMITED",
                "Too many handoff attempts; retry later",
                status_code=429,
                recoverable=True,
                retry_after=self.window_seconds,
            )

    async def aclose(self) -> None:
        await self._redis.aclose()
