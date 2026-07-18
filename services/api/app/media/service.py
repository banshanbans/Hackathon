from __future__ import annotations

import hashlib
from datetime import UTC, datetime, timedelta
from io import BytesIO
from pathlib import PurePosixPath
from typing import Literal, cast
from uuid import uuid4

from PIL import Image, UnidentifiedImageError

from app.domain.errors import DomainError, not_found
from app.domain.ids import new_id
from app.domain.models import JsonObject, MediaAsset
from app.media.storage import ObjectStorage
from app.persistence.store import MediaRecord, StateStore

CONTENT_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}
FORMAT_CONTENT_TYPES = {
    "JPEG": "image/jpeg",
    "PNG": "image/png",
    "WEBP": "image/webp",
}


class MediaService:
    def __init__(
        self,
        store: StateStore,
        storage: ObjectStorage,
        *,
        retention_hours: int = 24,
        upload_ttl_seconds: int = 600,
        access_ttl_seconds: int = 300,
    ) -> None:
        self.store = store
        self.storage = storage
        self.retention_hours = retention_hours
        self.upload_ttl_seconds = upload_ttl_seconds
        self.access_ttl_seconds = access_ttl_seconds

    async def create_upload(self, payload: JsonObject) -> JsonObject:
        session_id = str(payload["session_id"])
        if await self.store.get_session(session_id) is None:
            raise not_found("Session")
        media_asset_id = new_id("media")
        content_type = cast(
            Literal["image/jpeg", "image/png", "image/webp"], payload["content_type"]
        )
        object_key = str(
            PurePosixPath("sessions")
            / session_id
            / str(payload["purpose"])
            / f"{uuid4().hex}{CONTENT_EXTENSIONS[content_type]}"
        )
        now = datetime.now(UTC)
        asset = MediaAsset(
            media_asset_id=media_asset_id,
            session_id=session_id,
            purpose=payload["purpose"],
            content_type=content_type,
            byte_size=int(payload["byte_size"]),
            sha256=str(payload["sha256"]),
            status="pending_upload",
            width=None,
            height=None,
            expires_at=now + timedelta(hours=self.retention_hours),
            created_at=now,
        )
        await self.store.put_media(
            media_asset_id,
            session_id,
            asset.model_dump(mode="json"),
            object_key,
        )
        upload_expires_at = now + timedelta(seconds=self.upload_ttl_seconds)
        upload_url = await self.storage.create_upload_url(
            object_key, content_type, self.upload_ttl_seconds
        )
        return {
            "schema_version": "1.0",
            "asset": asset.model_dump(mode="json"),
            "upload_url": upload_url,
            "upload_headers": {"Content-Type": content_type},
            "upload_expires_at": upload_expires_at.isoformat(),
        }

    async def complete_upload(self, media_asset_id: str, session_id: str) -> JsonObject:
        record = await self._owned_record(media_asset_id, session_id)
        asset = MediaAsset.model_validate(record.asset)
        if asset.status == "ready":
            return asset.model_dump(mode="json")
        if asset.status != "pending_upload":
            raise DomainError(
                "MEDIA_NOT_READY",
                "Media upload cannot be completed from its current state",
                status_code=409,
                recoverable=True,
            )
        try:
            content = await self.storage.read(record.object_key)
        except FileNotFoundError as error:
            raise DomainError(
                "MEDIA_NOT_READY",
                "Uploaded media object was not found",
                status_code=409,
                recoverable=True,
            ) from error
        if len(content) != asset.byte_size:
            await self._mark_failed(record, asset)
            raise DomainError(
                "MEDIA_INTEGRITY_FAILED",
                "Uploaded media size does not match the request",
                status_code=422,
                recoverable=True,
            )
        if hashlib.sha256(content).hexdigest() != asset.sha256:
            await self._mark_failed(record, asset)
            raise DomainError(
                "MEDIA_INTEGRITY_FAILED",
                "Uploaded media checksum does not match the request",
                status_code=422,
                recoverable=True,
            )
        try:
            with Image.open(BytesIO(content)) as image:
                image.verify()
            with Image.open(BytesIO(content)) as image:
                width, height = image.size
                detected_content_type = FORMAT_CONTENT_TYPES.get(str(image.format).upper())
        except (UnidentifiedImageError, OSError) as error:
            await self._mark_failed(record, asset)
            raise DomainError(
                "UNSUPPORTED_MEDIA",
                "Uploaded file is not a supported image",
                status_code=422,
                recoverable=True,
            ) from error
        if detected_content_type != asset.content_type or width > 2048 or height > 2048:
            await self._mark_failed(record, asset)
            raise DomainError(
                "UNSUPPORTED_MEDIA",
                "Image type or dimensions do not match the accepted media policy",
                status_code=422,
                recoverable=True,
            )
        ready = asset.model_copy(
            update={"status": "ready", "width": width, "height": height}
        )
        await self.store.put_media(
            media_asset_id,
            session_id,
            ready.model_dump(mode="json"),
            record.object_key,
        )
        return ready.model_dump(mode="json")

    async def get_access(self, media_asset_id: str, session_id: str) -> JsonObject:
        record = await self._owned_record(media_asset_id, session_id)
        asset = MediaAsset.model_validate(record.asset)
        self._require_ready(asset)
        now = datetime.now(UTC)
        access_expires_at = now + timedelta(seconds=self.access_ttl_seconds)
        return {
            "schema_version": "1.0",
            "asset": asset.model_dump(mode="json"),
            "download_url": await self.storage.create_download_url(
                record.object_key, self.access_ttl_seconds
            ),
            "access_expires_at": access_expires_at.isoformat(),
        }

    async def load_for_model(self, media_asset_id: str) -> tuple[str, bytes]:
        record = await self.store.get_media(media_asset_id)
        if record is None:
            raise not_found("Media")
        asset = MediaAsset.model_validate(record.asset)
        self._require_ready(asset)
        return asset.content_type, await self.storage.read(record.object_key)

    async def delete_session_media(self, session_id: str) -> None:
        for record in await self.store.list_media_for_session(session_id):
            await self.storage.delete(record.object_key)
            media_asset_id = record.asset.get("media_asset_id")
            if isinstance(media_asset_id, str):
                await self.store.delete_media(media_asset_id)

    async def cleanup_expired(self, now: datetime | None = None) -> int:
        expired = await self.store.list_expired_media(now or datetime.now(UTC))
        for record in expired:
            await self.storage.delete(record.object_key)
            media_asset_id = record.asset.get("media_asset_id")
            if isinstance(media_asset_id, str):
                await self.store.delete_media(media_asset_id)
        return len(expired)

    async def _owned_record(self, media_asset_id: str, session_id: str) -> MediaRecord:
        record = await self.store.get_media(media_asset_id)
        if record is None:
            raise not_found("Media")
        if record.asset.get("session_id") != session_id:
            raise DomainError(
                "MEDIA_ACCESS_DENIED",
                "Media belongs to another session",
                status_code=404,
                recoverable=False,
            )
        return record

    async def _mark_failed(self, record: MediaRecord, asset: MediaAsset) -> None:
        failed = asset.model_copy(update={"status": "failed"})
        await self.store.put_media(
            asset.media_asset_id,
            asset.session_id,
            failed.model_dump(mode="json"),
            record.object_key,
        )

    @staticmethod
    def _require_ready(asset: MediaAsset) -> None:
        if asset.status != "ready" or asset.expires_at <= datetime.now(UTC):
            raise DomainError(
                "MEDIA_NOT_READY",
                "Media is not ready or has expired",
                status_code=409,
                recoverable=True,
            )
