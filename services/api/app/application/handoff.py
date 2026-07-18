from __future__ import annotations

import hashlib
import json
import secrets
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from uuid import NAMESPACE_URL, uuid5

from app.application.service import ServiceResult
from app.domain.errors import DomainError, not_found
from app.domain.ids import new_id
from app.domain.models import HandoffRecord, JsonObject, SoloShotSession
from app.handoff.rate_limit import HandoffRateLimiter
from app.handoff.tokens import HandoffTokenSigner
from app.media.service import MediaService
from app.persistence.store import IdempotencyRecord, StateStore

HANDOFF_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def _fingerprint(payload: JsonObject) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode()).hexdigest()


class HandoffService:
    def __init__(
        self,
        store: StateStore,
        media_service: MediaService,
        signer: HandoffTokenSigner,
        rate_limiter: HandoffRateLimiter,
        *,
        public_base_url: str,
        handoff_ttl_seconds: int = 600,
        claim_token_ttl_seconds: int = 86_400,
        lookup_limit_per_minute: int = 120,
        claim_limit_per_minute: int = 10,
        clock: Callable[[], datetime] | None = None,
        code_generator: Callable[[], str] | None = None,
    ) -> None:
        self.store = store
        self.media_service = media_service
        self.signer = signer
        self.rate_limiter = rate_limiter
        self.public_base_url = public_base_url.rstrip("/")
        self.handoff_ttl_seconds = handoff_ttl_seconds
        self.claim_token_ttl_seconds = claim_token_ttl_seconds
        self.lookup_limit_per_minute = lookup_limit_per_minute
        self.claim_limit_per_minute = claim_limit_per_minute
        self.clock = clock or (lambda: datetime.now(UTC))
        self.code_generator = code_generator or self._new_code

    @staticmethod
    def _new_code() -> str:
        return "".join(secrets.choice(HANDOFF_CODE_ALPHABET) for _ in range(6))

    async def create(self, payload: JsonObject, key: str) -> ServiceResult:
        fingerprint = _fingerprint(payload)
        session_id = str(payload["session_id"])
        async with self.store.transaction():
            existing_idempotency = await self._idempotency(
                "create_handoff", key, fingerprint
            )
            if existing_idempotency is not None:
                replay_code = str(existing_idempotency.data["code"])
                replay_payload = await self.store.get_handoff(replay_code)
                if replay_payload is None:
                    raise not_found("Handoff")
                return self._create_result(HandoffRecord.model_validate(replay_payload), 200)

            session = await self._require_session(session_id)
            self._validate_session_for_create(session)
            analysis = await self.store.get_analysis_for_session(session_id)
            if analysis is None or analysis.get("safety_status") == "block":
                raise DomainError(
                    "UNSAFE_INSTRUCTION",
                    "A safe active reference analysis is required for handoff",
                    status_code=422,
                    recoverable=True,
                )
            now = self.clock()
            latest_payload = await self.store.get_latest_handoff_for_session(session_id)
            latest = (
                None if latest_payload is None else HandoffRecord.model_validate(latest_payload)
            )
            if latest is not None and latest.status in {"created", "claimed"}:
                if latest.expires_at <= now:
                    latest = latest.model_copy(update={"status": "expired"})
                    await self.store.put_handoff(latest.model_dump(mode="json"))
                    session = await self._restore_session(session)
                elif latest.status == "created":
                    await self._save_idempotency(
                        "create_handoff", key, fingerprint, latest, 200
                    )
                    return self._create_result(latest, 200)
                else:
                    raise DomainError(
                        "HANDOFF_ALREADY_CLAIMED",
                        "This Session has already been claimed by an iPhone",
                        status_code=409,
                    )
            if latest is not None and latest.status == "completed":
                raise DomainError(
                    "HANDOFF_ALREADY_CLAIMED",
                    "This Session has already been imported to an iPhone",
                    status_code=409,
                )

            code = await self._unused_code()
            handoff = HandoffRecord(
                handoff_id=new_id("handoff"),
                code=code,
                session_id=session.session_id,
                status="created",
                mode=session.mode,
                created_at=now,
                expires_at=now + timedelta(seconds=self.handoff_ttl_seconds),
                claimed_at=None,
                completed_at=None,
                claimed_client_hash=None,
                claim_token_expires_at=None,
                revoked_at=None,
            )
            await self.store.put_handoff(handoff.model_dump(mode="json"))
            updated_session = session.model_copy(
                update={"state": "handoff_ready", "updated_at": now}
            )
            await self.store.put_session(
                session.session_id, updated_session.model_dump(mode="json")
            )
            await self._save_idempotency("create_handoff", key, fingerprint, handoff, 201)
            return self._create_result(handoff, 201)

    async def get(self, code: str, rate_identity: str) -> ServiceResult:
        await self.rate_limiter.consume(
            "lookup", rate_identity, self.lookup_limit_per_minute
        )
        expired = False
        record: HandoffRecord | None = None
        async with self.store.transaction():
            payload = await self.store.get_handoff(code)
            if payload is None:
                raise not_found("Handoff")
            record = HandoffRecord.model_validate(payload)
            if self._should_expire(record):
                record = record.model_copy(update={"status": "expired"})
                await self.store.put_handoff(record.model_dump(mode="json"))
                await self._restore_session_by_id(record.session_id)
                expired = True
        if expired or record is None:
            self._raise_expired()
        self._raise_if_gone(record)
        return ServiceResult(data=record.public_task().model_dump(mode="json"), status_code=200)

    async def claim(
        self, code: str, payload: JsonObject, key: str, rate_identity: str
    ) -> ServiceResult:
        await self.rate_limiter.consume(
            "claim", rate_identity, self.claim_limit_per_minute
        )
        fingerprint = _fingerprint(payload)
        client_hash = self.signer.client_hash(str(payload["client_instance_id"]))
        expired = False
        result: ServiceResult | None = None
        async with self.store.transaction():
            existing_idempotency = await self._idempotency(
                f"claim_handoff:{code}", key, fingerprint
            )
            handoff_payload = await self.store.get_handoff(code)
            if handoff_payload is None:
                raise not_found("Handoff")
            handoff = HandoffRecord.model_validate(handoff_payload)
            if self._should_expire(handoff):
                handoff = handoff.model_copy(update={"status": "expired"})
                await self.store.put_handoff(handoff.model_dump(mode="json"))
                await self._restore_session_by_id(handoff.session_id)
                expired = True
            elif handoff.status == "revoked":
                self._raise_revoked()
            elif handoff.status in {"claimed", "completed"}:
                if handoff.claimed_client_hash != client_hash:
                    raise DomainError(
                        "HANDOFF_ALREADY_CLAIMED",
                        "Handoff was already claimed by another device",
                        status_code=409,
                    )
                result = await self._claim_result(handoff, allow_missing_media=True)
            else:
                session = await self._require_session(handoff.session_id)
                self._validate_session_for_claim(session)
                reference_access = await self._reference_access(session, required=True)
                now = self.clock()
                handoff = handoff.model_copy(
                    update={
                        "status": "claimed",
                        "claimed_at": now,
                        "claimed_client_hash": client_hash,
                        "claim_token_expires_at": now
                        + timedelta(seconds=self.claim_token_ttl_seconds),
                    }
                )
                await self.store.put_handoff(handoff.model_dump(mode="json"))
                result = self._build_claim_result(handoff, session, reference_access)
            if not expired:
                if existing_idempotency is None:
                    await self._save_idempotency(
                        f"claim_handoff:{code}", key, fingerprint, handoff, 200
                    )
                elif existing_idempotency.data.get("client_hash") != client_hash:
                    raise DomainError(
                        "IDEMPOTENCY_CONFLICT",
                        "Idempotency-Key was already used by another client",
                        status_code=409,
                    )
        if expired:
            self._raise_expired()
        if result is None:
            raise RuntimeError("claim result missing")
        return result

    async def revoke(
        self, code: str, management_token: str, key: str
    ) -> ServiceResult:
        payload = {"code": code, "management_token_hash": hashlib.sha256(
            management_token.encode("utf-8")
        ).hexdigest()}
        fingerprint = _fingerprint(payload)
        expired = False
        result: ServiceResult | None = None
        async with self.store.transaction():
            existing_idempotency = await self._idempotency(
                f"revoke_handoff:{code}", key, fingerprint
            )
            handoff_payload = await self.store.get_handoff(code)
            if handoff_payload is None:
                raise not_found("Handoff")
            handoff = HandoffRecord.model_validate(handoff_payload)
            if self._should_expire(handoff):
                handoff = handoff.model_copy(update={"status": "expired"})
                await self.store.put_handoff(handoff.model_dump(mode="json"))
                await self._restore_session_by_id(handoff.session_id)
                expired = True
            else:
                self.signer.verify(
                    management_token, "management", handoff, self.clock()
                )
                if handoff.status == "completed":
                    raise DomainError(
                        "INVALID_STATE",
                        "A completed handoff cannot be revoked",
                        status_code=409,
                    )
                if handoff.status != "revoked":
                    handoff = handoff.model_copy(
                        update={"status": "revoked", "revoked_at": self.clock()}
                    )
                    await self.store.put_handoff(handoff.model_dump(mode="json"))
                    await self._restore_session_by_id(handoff.session_id)
                if existing_idempotency is None:
                    await self._save_idempotency(
                        f"revoke_handoff:{code}", key, fingerprint, handoff, 200
                    )
                result = ServiceResult(
                    data=handoff.public_task().model_dump(mode="json"), status_code=200
                )
        if expired:
            self._raise_expired()
        if result is None:
            raise RuntimeError("revoke result missing")
        return result

    async def complete(
        self, code: str, payload: JsonObject, claim_token: str, key: str
    ) -> ServiceResult:
        fingerprint = _fingerprint(payload)
        client_hash = self.signer.client_hash(str(payload["client_instance_id"]))
        expired = False
        result: ServiceResult | None = None
        async with self.store.transaction():
            existing_idempotency = await self._idempotency(
                f"complete_handoff:{code}", key, fingerprint
            )
            handoff_payload = await self.store.get_handoff(code)
            if handoff_payload is None:
                raise not_found("Handoff")
            handoff = HandoffRecord.model_validate(handoff_payload)
            if self._should_expire(handoff):
                handoff = handoff.model_copy(update={"status": "expired"})
                await self.store.put_handoff(handoff.model_dump(mode="json"))
                await self._restore_session_by_id(handoff.session_id)
                expired = True
            elif handoff.status == "revoked":
                self._raise_revoked()
            else:
                if handoff.claimed_client_hash != client_hash:
                    raise DomainError(
                        "HANDOFF_INVALID_TOKEN",
                        "Claim token is not bound to this client",
                        status_code=401,
                    )
                self.signer.verify(
                    claim_token,
                    "claim",
                    handoff,
                    self.clock(),
                    client_hash=client_hash,
                )
                if handoff.status == "created":
                    raise DomainError(
                        "INVALID_STATE",
                        "Handoff must be claimed before completion",
                        status_code=409,
                    )
                if handoff.status != "completed":
                    now = self.clock()
                    handoff = handoff.model_copy(
                        update={"status": "completed", "completed_at": now}
                    )
                    await self.store.put_handoff(handoff.model_dump(mode="json"))
                    await self._record_completed_event(handoff)
                if existing_idempotency is None:
                    await self._save_idempotency(
                        f"complete_handoff:{code}", key, fingerprint, handoff, 200
                    )
                result = ServiceResult(
                    data=handoff.public_task().model_dump(mode="json"), status_code=200
                )
        if expired:
            self._raise_expired()
        if result is None:
            raise RuntimeError("complete result missing")
        return result

    async def cleanup_expired(self) -> int:
        now = self.clock()
        candidates = await self.store.list_expired_handoffs(now)
        count = 0
        for payload in candidates:
            async with self.store.transaction():
                latest_payload = await self.store.get_handoff(str(payload["code"]))
                if latest_payload is None:
                    continue
                record = HandoffRecord.model_validate(latest_payload)
                if not self._should_expire(record):
                    continue
                record = record.model_copy(update={"status": "expired"})
                await self.store.put_handoff(record.model_dump(mode="json"))
                await self._restore_session_by_id(record.session_id)
                count += 1
        return count

    async def _unused_code(self) -> str:
        for _ in range(20):
            code = self.code_generator()
            if await self.store.get_handoff(code) is None:
                return code
        raise DomainError(
            "INTERNAL_ERROR",
            "Unable to allocate a handoff code",
            status_code=503,
            recoverable=True,
        )

    async def _require_session(self, session_id: str) -> SoloShotSession:
        payload = await self.store.get_session(session_id)
        if payload is None:
            raise not_found("Session")
        return SoloShotSession.model_validate(payload)

    @staticmethod
    def _validate_session_for_create(session: SoloShotSession) -> None:
        if (
            session.shot_plan is None
            or not session.shot_plan.ios_execution.supported
            or session.capture_rounds
            or session.state not in {"shot_plan_ready", "handoff_ready"}
        ):
            raise DomainError(
                "INVALID_STATE",
                "Handoff requires an uncaptured, iOS-compatible ShotPlan",
                status_code=409,
                recoverable=True,
            )

    @staticmethod
    def _validate_session_for_claim(session: SoloShotSession) -> None:
        if (
            session.shot_plan is None
            or not session.shot_plan.ios_execution.supported
            or session.capture_rounds
            or session.state != "handoff_ready"
        ):
            raise DomainError(
                "INVALID_STATE",
                "The Session is no longer ready for iOS import",
                status_code=409,
            )

    async def _reference_access(
        self, session: SoloShotSession, *, required: bool
    ) -> JsonObject | None:
        media_asset_id = (
            None if session.reference_asset is None else session.reference_asset.media_asset_id
        )
        if media_asset_id is None:
            return None
        try:
            return await self.media_service.get_access(media_asset_id, session.session_id)
        except DomainError as error:
            if not required:
                return None
            raise DomainError(
                "SESSION_EXPIRED",
                "Reference media expired before the handoff was claimed",
                status_code=410,
                recoverable=True,
            ) from error

    async def _claim_result(
        self, handoff: HandoffRecord, *, allow_missing_media: bool
    ) -> ServiceResult:
        session = await self._require_session(handoff.session_id)
        reference_access = await self._reference_access(
            session, required=not allow_missing_media
        )
        return self._build_claim_result(handoff, session, reference_access)

    def _build_claim_result(
        self,
        handoff: HandoffRecord,
        session: SoloShotSession,
        reference_access: JsonObject | None,
    ) -> ServiceResult:
        if handoff.claimed_client_hash is None or handoff.claim_token_expires_at is None:
            raise RuntimeError("claimed handoff is missing claimant metadata")
        claim_token = self.signer.sign(
            "claim",
            handoff,
            handoff.claim_token_expires_at,
            client_hash=handoff.claimed_client_hash,
        )
        return ServiceResult(
            data={
                "schema_version": "1.0",
                "handoff": handoff.public_task().model_dump(mode="json"),
                "session": session.model_dump(mode="json"),
                "claim_token": claim_token,
                "reference_access": reference_access,
            },
            status_code=200,
        )

    def _create_result(self, handoff: HandoffRecord, status_code: int) -> ServiceResult:
        management_token = self.signer.sign(
            "management", handoff, handoff.expires_at
        )
        return ServiceResult(
            data={
                "schema_version": "1.0",
                "handoff": handoff.public_task().model_dump(mode="json"),
                "management_token": management_token,
                "qr_payload": f"{self.public_base_url}/{handoff.code}",
            },
            status_code=status_code,
        )

    async def _restore_session(self, session: SoloShotSession) -> SoloShotSession:
        if session.state != "handoff_ready":
            return session
        restored = session.model_copy(
            update={"state": "shot_plan_ready", "updated_at": self.clock()}
        )
        await self.store.put_session(session.session_id, restored.model_dump(mode="json"))
        return restored

    async def _restore_session_by_id(self, session_id: str) -> None:
        payload = await self.store.get_session(session_id)
        if payload is not None:
            await self._restore_session(SoloShotSession.model_validate(payload))

    def _should_expire(self, handoff: HandoffRecord) -> bool:
        return handoff.status in {"created", "claimed"} and handoff.expires_at <= self.clock()

    @staticmethod
    def _raise_expired() -> None:
        raise DomainError(
            "HANDOFF_EXPIRED",
            "Handoff code has expired",
            status_code=410,
            recoverable=True,
        )

    @staticmethod
    def _raise_revoked() -> None:
        raise DomainError(
            "HANDOFF_REVOKED",
            "Handoff code was revoked",
            status_code=410,
            recoverable=False,
        )

    def _raise_if_gone(self, handoff: HandoffRecord) -> None:
        if handoff.status == "expired":
            self._raise_expired()
        if handoff.status == "revoked":
            self._raise_revoked()

    async def _idempotency(
        self, operation: str, key: str, fingerprint: str
    ) -> IdempotencyRecord | None:
        existing = await self.store.get_idempotency(operation, key)
        if existing is not None and existing.fingerprint != fingerprint:
            raise DomainError(
                "IDEMPOTENCY_CONFLICT",
                "Idempotency-Key was already used with a different request",
                status_code=409,
            )
        return existing

    async def _save_idempotency(
        self,
        operation: str,
        key: str,
        fingerprint: str,
        handoff: HandoffRecord,
        status_code: int,
    ) -> None:
        data: JsonObject = {
            "handoff_id": handoff.handoff_id,
            "code": handoff.code,
        }
        if handoff.claimed_client_hash is not None:
            data["client_hash"] = handoff.claimed_client_hash
        await self.store.put_idempotency(
            operation,
            key,
            IdempotencyRecord(
                fingerprint=fingerprint,
                status_code=status_code,
                data=data,
                execution_mode=None,
                owner_session_id=handoff.session_id,
            ),
        )

    async def _record_completed_event(self, handoff: HandoffRecord) -> None:
        session = await self._require_session(handoff.session_id)
        latency_ms = 0
        if handoff.claimed_at is not None and handoff.completed_at is not None:
            latency_ms = max(
                0, int((handoff.completed_at - handoff.claimed_at).total_seconds() * 1000)
            )
        await self.store.put_events(
            [
                {
                    "schema_version": "1.0",
                    "event_id": str(
                        uuid5(NAMESPACE_URL, f"soloshot:{handoff.handoff_id}:completed")
                    ),
                    "event_name": "handoff_claimed",
                    "session_id": handoff.session_id,
                    "source_channel": session.source_channel,
                    "client": "ios",
                    "timestamp": self.clock().isoformat(),
                    "properties": {"status": "completed", "latency_ms": latency_ms},
                }
            ]
        )
