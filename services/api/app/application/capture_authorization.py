from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime
from typing import Literal, Never

from app.domain.errors import DomainError
from app.domain.models import HandoffRecord
from app.handoff.tokens import HandoffTokenSigner
from app.persistence.store import StateStore

CaptureClient = Literal["h5", "ios"]


class CaptureAuthorizationService:
    """Authorizes capture mutations without exposing Handoff rules to routes."""

    def __init__(
        self,
        store: StateStore,
        signer: HandoffTokenSigner,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.store = store
        self.signer = signer
        self.clock = clock or (lambda: datetime.now(UTC))

    async def authorize_write(
        self,
        session_id: str,
        claim_token: str | None,
    ) -> CaptureClient:
        payload = await self.store.get_latest_handoff_for_session(session_id)
        if payload is None:
            return "h5"
        handoff = HandoffRecord.model_validate(payload)
        if handoff.status in {"revoked", "expired"}:
            return "h5"
        if handoff.status in {"created", "claimed"}:
            raise DomainError(
                "INVALID_STATE",
                "Capture writes are locked while Handoff import is in progress",
                status_code=409,
                recoverable=True,
            )
        self._verify_claim(handoff, claim_token)
        return "ios"

    async def authorize_ios(
        self,
        session_id: str,
        claim_token: str | None,
    ) -> None:
        payload = await self.store.get_latest_handoff_for_session(session_id)
        if payload is None:
            self._invalid_token()
        handoff = HandoffRecord.model_validate(payload)
        if handoff.status != "completed":
            raise DomainError(
                "INVALID_STATE",
                "Capture consent requires a completed iOS Handoff",
                status_code=409,
                recoverable=True,
            )
        self._verify_claim(handoff, claim_token)

    def _verify_claim(self, handoff: HandoffRecord, claim_token: str | None) -> None:
        if claim_token is None or handoff.claimed_client_hash is None:
            self._invalid_token()
        self.signer.verify(
            claim_token,
            "claim",
            handoff,
            self.clock(),
            client_hash=handoff.claimed_client_hash,
        )

    @staticmethod
    def _invalid_token() -> Never:
        raise DomainError(
            "HANDOFF_INVALID_TOKEN",
            "A valid iOS claim capability is required",
            status_code=401,
            recoverable=False,
        )
