from __future__ import annotations


class DomainError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        status_code: int = 422,
        recoverable: bool = False,
        retry_after: int | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.recoverable = recoverable
        self.retry_after = retry_after


def not_found(resource: str) -> DomainError:
    return DomainError("NOT_FOUND", f"{resource} was not found", status_code=404)
