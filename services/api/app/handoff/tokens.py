from __future__ import annotations

import base64
import hashlib
import hmac
import json
from datetime import UTC, datetime
from typing import Literal

from app.domain.errors import DomainError
from app.domain.models import HandoffRecord

TokenRole = Literal["management", "claim"]


def _encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


class HandoffTokenSigner:
    def __init__(self, secret: str) -> None:
        self._secret = secret.encode("utf-8")

    @staticmethod
    def client_hash(client_instance_id: str) -> str:
        return hashlib.sha256(client_instance_id.encode("utf-8")).hexdigest()

    def sign(
        self,
        role: TokenRole,
        handoff: HandoffRecord,
        expires_at: datetime,
        *,
        client_hash: str | None = None,
    ) -> str:
        payload = {
            "v": 1,
            "role": role,
            "handoff_id": handoff.handoff_id,
            "client_hash": client_hash,
            "exp": int(expires_at.timestamp()),
        }
        encoded = _encode(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        )
        signature = _encode(
            hmac.new(self._secret, encoded.encode("ascii"), hashlib.sha256).digest()
        )
        return f"{encoded}.{signature}"

    def verify(
        self,
        token: str,
        role: TokenRole,
        handoff: HandoffRecord,
        now: datetime,
        *,
        client_hash: str | None = None,
    ) -> None:
        try:
            encoded, provided_signature = token.split(".", 1)
            expected_signature = _encode(
                hmac.new(self._secret, encoded.encode("ascii"), hashlib.sha256).digest()
            )
            if not hmac.compare_digest(provided_signature, expected_signature):
                raise ValueError("signature mismatch")
            payload = json.loads(_decode(encoded))
            if not isinstance(payload, dict):
                raise ValueError("invalid payload")
            expires_at = datetime.fromtimestamp(int(payload["exp"]), UTC)
            if expires_at <= now:
                raise ValueError("token expired")
            if (
                payload.get("v") != 1
                or payload.get("role") != role
                or payload.get("handoff_id") != handoff.handoff_id
                or payload.get("client_hash") != client_hash
            ):
                raise ValueError("claims mismatch")
        except (KeyError, TypeError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
            raise DomainError(
                "HANDOFF_INVALID_TOKEN",
                "Handoff capability is invalid or expired",
                status_code=401,
            ) from None
