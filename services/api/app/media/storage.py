from __future__ import annotations

import asyncio
from typing import Protocol

import boto3  # type: ignore[import-untyped]
from botocore.client import Config  # type: ignore[import-untyped]


class ObjectStorage(Protocol):
    async def create_upload_url(
        self, object_key: str, content_type: str, expires_seconds: int
    ) -> str: ...

    async def create_download_url(self, object_key: str, expires_seconds: int) -> str: ...
    async def read(self, object_key: str) -> bytes: ...
    async def delete(self, object_key: str) -> None: ...


class MemoryObjectStorage:
    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}

    async def create_upload_url(
        self, object_key: str, content_type: str, expires_seconds: int
    ) -> str:
        return f"memory://upload/{object_key}"

    async def create_download_url(self, object_key: str, expires_seconds: int) -> str:
        return f"memory://download/{object_key}"

    async def read(self, object_key: str) -> bytes:
        if object_key not in self.objects:
            raise FileNotFoundError(object_key)
        return self.objects[object_key]

    async def delete(self, object_key: str) -> None:
        self.objects.pop(object_key, None)

    def put_for_test(self, object_key: str, content: bytes) -> None:
        self.objects[object_key] = content


class S3ObjectStorage:
    def __init__(
        self,
        *,
        endpoint: str,
        public_endpoint: str,
        bucket: str,
        access_key: str,
        secret_key: str,
        region: str = "us-east-1",
    ) -> None:
        options = {
            "aws_access_key_id": access_key,
            "aws_secret_access_key": secret_key,
            "region_name": region,
            "config": Config(signature_version="s3v4", s3={"addressing_style": "path"}),
        }
        self._bucket = bucket
        self._internal = boto3.client("s3", endpoint_url=endpoint, **options)
        self._public = boto3.client("s3", endpoint_url=public_endpoint, **options)

    async def create_upload_url(
        self, object_key: str, content_type: str, expires_seconds: int
    ) -> str:
        return await asyncio.to_thread(
            self._public.generate_presigned_url,
            "put_object",
            Params={
                "Bucket": self._bucket,
                "Key": object_key,
                "ContentType": content_type,
            },
            ExpiresIn=expires_seconds,
        )

    async def create_download_url(self, object_key: str, expires_seconds: int) -> str:
        return await asyncio.to_thread(
            self._public.generate_presigned_url,
            "get_object",
            Params={"Bucket": self._bucket, "Key": object_key},
            ExpiresIn=expires_seconds,
        )

    async def read(self, object_key: str) -> bytes:
        def download() -> bytes:
            response = self._internal.get_object(Bucket=self._bucket, Key=object_key)
            return bytes(response["Body"].read())

        return await asyncio.to_thread(download)

    async def delete(self, object_key: str) -> None:
        await asyncio.to_thread(
            self._internal.delete_object,
            Bucket=self._bucket,
            Key=object_key,
        )
