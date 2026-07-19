from __future__ import annotations

import hashlib
import json
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import uuid4

from app.agent.orchestrator import append_skill_runs, new_agent_run
from app.application.capture_authorization import CaptureAuthorizationService
from app.domain.errors import DomainError, not_found
from app.domain.ids import new_id
from app.domain.models import (
    AgentRun,
    Capture,
    JsonObject,
    MediaAsset,
    PostJob,
    ReferenceAnalysis,
    ReferenceAsset,
    ResultEvaluation,
    ShotPlan,
    SoloShotSession,
)
from app.media.service import MediaService
from app.persistence.store import IdempotencyRecord, StateStore
from app.skills.registry import SkillRegistry
from app.skills.runtime import SkillInvocation


@dataclass(frozen=True)
class ServiceResult:
    data: JsonObject
    status_code: int
    execution_mode: str | None = None


def _fingerprint(payload: JsonObject) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode()).hexdigest()


class W1Service:
    """Application service retained under its W1 name for API compatibility."""

    SAFE_EVENT_PROPERTIES = {
        "mode",
        "source",
        "case_id",
        "execution_mode",
        "latency_ms",
        "round_index",
        "route",
        "reference_source",
        "status",
        "error_code",
    }
    FORBIDDEN_EVENT_FRAGMENTS = {
        "base64",
        "filename",
        "file_name",
        "media",
        "token",
        "url",
        "secret",
        "key",
    }

    def __init__(
        self,
        store: StateStore,
        registry: SkillRegistry,
        provider_name: str,
        execution_mode: str,
        media_service: MediaService,
        capture_authorization: CaptureAuthorizationService,
    ) -> None:
        self.store = store
        self.registry = registry
        self.provider_name = provider_name
        self.execution_mode = execution_mode
        self.media_service = media_service
        self.capture_authorization = capture_authorization

    async def _idempotent(
        self,
        operation: str,
        key: str,
        payload: JsonObject,
        action: Callable[[], Awaitable[ServiceResult]],
    ) -> ServiceResult:
        fingerprint = _fingerprint(payload)
        async with self.store.transaction():
            existing = await self.store.get_idempotency(operation, key)
            if existing is not None:
                if existing.fingerprint != fingerprint:
                    raise DomainError(
                        "IDEMPOTENCY_CONFLICT",
                        "Idempotency-Key was already used with a different request",
                        status_code=409,
                    )
                return ServiceResult(
                    data=existing.data,
                    status_code=existing.status_code,
                    execution_mode=("cache" if existing.execution_mode is not None else None),
                )
            result = await action()
            owner_session_id = result.data.get("session_id") or payload.get("session_id")
            if not isinstance(owner_session_id, str) or operation.startswith("delete_session:"):
                owner_session_id = None
            await self.store.put_idempotency(
                operation,
                key,
                IdempotencyRecord(
                    fingerprint=fingerprint,
                    status_code=result.status_code,
                    data=result.data,
                    execution_mode=result.execution_mode,
                    owner_session_id=owner_session_id,
                ),
            )
            return result

    async def require_session(self, session_id: str) -> SoloShotSession:
        payload = await self.store.get_session(session_id)
        if payload is None:
            raise not_found("Session")
        return SoloShotSession.model_validate(payload)

    async def create_session(self, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            now = datetime.now(UTC)
            source = str(payload["source_channel"])
            session = SoloShotSession(
                session_id=new_id("ss"),
                state="created",
                source_channel=payload["source_channel"],
                mode=payload["mode"],
                reference_asset=None,
                scene_asset_id=None,
                active_reference_analysis_id=None,
                user_constraints=payload["user_constraints"],
                selected_skills=[],
                shot_plan=None,
                capture_rounds=[],
                evaluation=None,
                evaluations=[],
                external_ai_consent_at=(now if payload.get("external_ai_consent") else None),
                capture_upload_consent_at=None,
                publish_package=None,
                analytics_context={
                    "client": "ios" if source == "ios" else "h5",
                    "campaign": None,
                },
                created_at=now,
                updated_at=now,
            )
            data = session.model_dump(mode="json")
            await self.store.put_session(session.session_id, data)
            return ServiceResult(data=data, status_code=201)

        return await self._idempotent("create_session", key, payload, action)

    async def get_session(self, session_id: str) -> ServiceResult:
        session = await self.require_session(session_id)
        return ServiceResult(data=session.model_dump(mode="json"), status_code=200)

    async def delete_session(self, session_id: str, key: str) -> ServiceResult:
        payload = {"session_id": session_id}

        async def action() -> ServiceResult:
            await self.require_session(session_id)
            await self.media_service.delete_session_media(session_id)
            if not await self.store.delete_session(session_id):
                raise not_found("Session")
            return ServiceResult(data={"schema_version": "1.0", "deleted": True}, status_code=200)

        return await self._idempotent(f"delete_session:{session_id}", key, payload, action)

    async def record_capture_consent(
        self,
        session_id: str,
        payload: JsonObject,
        key: str,
        claim_token: str,
    ) -> ServiceResult:
        await self.capture_authorization.authorize_ios(session_id, claim_token)

        async def action() -> ServiceResult:
            session = await self.require_session(session_id)
            if session.state not in {"handoff_ready", "capturing", "coaching"}:
                raise DomainError(
                    "INVALID_STATE",
                    "Capture consent is unavailable in the current Session state",
                    status_code=409,
                    recoverable=True,
                )
            is_fixture = self._uses_fixture_evaluation(session)
            if not is_fixture and not payload["external_ai_consent"]:
                raise DomainError(
                    "CONSENT_REQUIRED",
                    "Live evaluation requires explicit external AI consent",
                    status_code=409,
                    recoverable=True,
                )
            now = datetime.now(UTC)
            external_at = (
                now if payload["external_ai_consent"] else session.external_ai_consent_at
            )
            updated = session.model_copy(
                update={
                    "capture_upload_consent_at": now,
                    "external_ai_consent_at": external_at,
                    "updated_at": now,
                }
            )
            await self.store.put_session(session_id, updated.model_dump(mode="json"))
            return ServiceResult(
                data={
                    "schema_version": "1.0",
                    "session_id": session_id,
                    "capture_upload_consent_at": now.isoformat(),
                    "external_ai_consent_at": (
                        None if external_at is None else external_at.isoformat()
                    ),
                },
                status_code=200,
            )

        return await self._idempotent(
            f"capture_consent:{session_id}", key, payload, action
        )

    async def create_media_upload(
        self, payload: JsonObject, key: str, claim_token: str | None = None
    ) -> ServiceResult:
        session_id = str(payload["session_id"])
        if payload["purpose"] == "capture":
            await self.capture_authorization.authorize_write(session_id, claim_token)

        async def action() -> ServiceResult:
            session = await self.require_session(session_id)
            if payload["purpose"] == "capture":
                self._require_capture_upload_consent(session)
            else:
                self._require_external_consent(session)
            data = await self.media_service.create_upload(payload)
            return ServiceResult(data=data, status_code=201)

        return await self._idempotent("create_media_upload", key, payload, action)

    async def complete_media_upload(
        self,
        media_asset_id: str,
        payload: JsonObject,
        key: str,
        claim_token: str | None = None,
    ) -> ServiceResult:
        record = await self.store.get_media(media_asset_id)
        if record is not None and record.asset.get("purpose") == "capture":
            await self.capture_authorization.authorize_write(
                str(payload["session_id"]), claim_token
            )

        async def action() -> ServiceResult:
            data = await self.media_service.complete_upload(
                media_asset_id, str(payload["session_id"])
            )
            return ServiceResult(data=data, status_code=200)

        return await self._idempotent(
            f"complete_media_upload:{media_asset_id}", key, payload, action
        )

    async def get_media_access(self, media_asset_id: str, session_id: str) -> ServiceResult:
        data = await self.media_service.get_access(media_asset_id, session_id)
        return ServiceResult(data=data, status_code=200)

    async def analyze_reference(self, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            session = await self.require_session(str(payload["session_id"]))
            if session.capture_rounds:
                raise DomainError(
                    "INVALID_STATE",
                    "Reference cannot be replaced after capture has started",
                    status_code=409,
                )
            asset = ReferenceAsset.model_validate(payload["reference_asset"])
            if asset.source_type == "upload":
                self._require_external_consent(session)
                if asset.media_asset_id is None:
                    raise DomainError(
                        "VALIDATION_FAILED",
                        "Uploaded reference requires media_asset_id",
                        status_code=422,
                    )
                await self._require_media(session, asset.media_asset_id, "reference")
            invocation = await self.registry.get("reference_understanding").invoke(
                {"reference_asset": asset.model_dump(mode="json")}
            )
            analysis_payload = {
                **invocation.output,
                "analysis_id": new_id("ra"),
                "reference_id": asset.reference_id,
            }
            analysis = ReferenceAnalysis.model_validate(analysis_payload)
            await self.store.put_reference(
                analysis.reference_id,
                session.session_id,
                asset.model_dump(mode="json"),
                analysis.model_dump(mode="json"),
            )
            updated = session.model_copy(
                update={
                    "state": "reference_ready",
                    "reference_asset": asset,
                    "scene_asset_id": None,
                    "active_reference_analysis_id": analysis.analysis_id,
                    "selected_skills": [],
                    "shot_plan": None,
                    "capture_rounds": [],
                    "evaluation": None,
                    "evaluations": [],
                    "publish_package": None,
                    "updated_at": datetime.now(UTC),
                }
            )
            await self.store.put_session(session.session_id, updated.model_dump(mode="json"))
            await self._persist_skill_invocation(invocation, session.session_id, None, 0)
            return ServiceResult(
                data=analysis.model_dump(mode="json"),
                status_code=202,
                execution_mode=invocation.execution_mode,
            )

        return await self._idempotent("analyze_reference", key, payload, action)

    async def adapt_reference(self, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            session = await self.require_session(str(payload["session_id"]))
            if session.mode != "scene_adaptation":
                raise DomainError(
                    "INVALID_STATE", "Session is not in scene adaptation mode", status_code=409
                )
            if session.reference_asset is None or (
                session.reference_asset.reference_id != payload["reference_id"]
            ):
                raise DomainError(
                    "INVALID_STATE", "Reference does not match Session", status_code=409
                )
            if session.capture_rounds:
                raise DomainError(
                    "INVALID_STATE", "Scene cannot be replaced after capture", status_code=409
                )
            self._require_external_consent(session)
            scene_asset_id = str(payload["scene_asset_id"])
            await self._require_media(session, scene_asset_id, "scene")
            current_analysis = await self._active_analysis(session)
            invocation = await self.registry.get("scene_adaptation").invoke(
                {
                    "reference_asset": session.reference_asset.model_dump(mode="json"),
                    "reference_analysis": current_analysis.model_dump(mode="json"),
                    "scene_asset_id": scene_asset_id,
                    "user_constraints": session.user_constraints.model_dump(mode="json"),
                }
            )
            analysis = ReferenceAnalysis.model_validate(
                {
                    **invocation.output,
                    "analysis_id": new_id("ra"),
                    "reference_id": session.reference_asset.reference_id,
                }
            )
            await self.store.put_reference_analysis(
                analysis.reference_id,
                session.session_id,
                analysis.model_dump(mode="json"),
                "scene_adapted",
            )
            updated = session.model_copy(
                update={
                    "state": "reference_ready",
                    "scene_asset_id": scene_asset_id,
                    "active_reference_analysis_id": analysis.analysis_id,
                    "selected_skills": [],
                    "shot_plan": None,
                    "evaluation": None,
                    "evaluations": [],
                    "updated_at": datetime.now(UTC),
                }
            )
            await self.store.put_session(session.session_id, updated.model_dump(mode="json"))
            await self._persist_skill_invocation(invocation, session.session_id, None, 0)
            return ServiceResult(
                data=analysis.model_dump(mode="json"),
                status_code=202,
                execution_mode=invocation.execution_mode,
            )

        return await self._idempotent("adapt_reference", key, payload, action)

    async def get_reference(self, reference_id: str) -> ServiceResult:
        payload = await self.store.get_reference(reference_id)
        if payload is None:
            raise not_found("Reference")
        return ServiceResult(data=payload, status_code=200)

    async def validate_reference_box(self, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            if await self.store.get_reference(str(payload["reference_id"])) is None:
                raise not_found("Reference")
            box = payload["selected_box"]
            warnings: list[str] = []
            if float(box["width"]) * float(box["height"]) < 0.02:
                warnings.append("选择区域过小，参考理解置信度可能降低。")
            return ServiceResult(
                data={"schema_version": "1.0", "valid": not warnings, "warnings": warnings},
                status_code=200,
            )

        return await self._idempotent("validate_reference_box", key, payload, action)

    async def create_agent_run(self, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            session = await self.require_session(str(payload["session_id"]))
            intent = str(payload["intent"])
            if intent != session.mode:
                raise DomainError(
                    "INVALID_STATE", "Agent intent must match the Session mode", status_code=409
                )
            if session.reference_asset is None or session.state != "reference_ready":
                raise DomainError(
                    "INVALID_STATE", "Agent planning requires an active reference", status_code=409
                )
            analysis = await self._active_analysis(session)
            if analysis.safety_status == "block":
                raise DomainError(
                    "UNSAFE_INSTRUCTION",
                    "Reference analysis blocks generation of a shooting plan",
                    status_code=422,
                    recoverable=True,
                )
            if session.mode == "scene_adaptation" and session.scene_asset_id is None:
                raise DomainError(
                    "INVALID_STATE", "Scene adaptation is required before planning", status_code=409
                )
            run = new_agent_run(session.session_id, payload["intent"], self.provider_name, None)
            invocation = await self.registry.get("shooting_plan").invoke(
                {
                    "reference_asset": session.reference_asset.model_dump(mode="json"),
                    "reference_analysis": analysis.model_dump(mode="json"),
                    "user_constraints": session.user_constraints.model_dump(mode="json"),
                    "mode": session.mode,
                    "scene_asset_id": session.scene_asset_id,
                }
            )
            plan = ShotPlan.model_validate({**invocation.output, "plan_id": new_id("sp")})
            run = append_skill_runs(run, [invocation.run])
            await self.store.put_agent_run(
                run.run_id, session.session_id, run.model_dump(mode="json")
            )
            await self._persist_skill_invocation(invocation, session.session_id, run.run_id, 0)
            await self.store.put_shot_plan(
                plan.plan_id, session.session_id, plan.model_dump(mode="json")
            )
            updated = session.model_copy(
                update={
                    "state": "shot_plan_ready",
                    "selected_skills": run.selected_skills,
                    "shot_plan": plan,
                    "updated_at": datetime.now(UTC),
                }
            )
            await self.store.put_session(session.session_id, updated.model_dump(mode="json"))
            return ServiceResult(
                data=run.model_dump(mode="json"),
                status_code=202,
                execution_mode=invocation.execution_mode,
            )

        return await self._idempotent("create_agent_run", key, payload, action)

    async def continue_agent_run(self, run_id: str, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            run_payload = await self.store.get_agent_run(run_id)
            if run_payload is None:
                raise not_found("Agent run")
            run = AgentRun.model_validate(run_payload)
            session = await self.require_session(str(payload["session_id"]))
            if run.session_id != session.session_id:
                raise DomainError(
                    "INVALID_STATE", "Agent run belongs to another session", status_code=409
                )
            if any(item.name == "result_evaluation" for item in run.selected_skills):
                raise DomainError(
                    "INVALID_STATE", "Agent run has already evaluated a capture", status_code=409
                )
            capture = await self._require_latest_capture(session, str(payload["capture_id"]))
            evaluation, evaluation_invocation = await self._evaluate(session, capture)
            content_invocation = await self.registry.get("content_composer").invoke(
                {"session_id": session.session_id, "format": "before_after_image"}
            )
            post = PostJob.model_validate(content_invocation.output)
            position = len(await self.store.get_skill_runs(run_id))
            for offset, invocation in enumerate((evaluation_invocation, content_invocation)):
                await self._persist_skill_invocation(
                    invocation, session.session_id, run_id, position + offset
                )
            run = append_skill_runs(run, [evaluation_invocation.run, content_invocation.run])
            await self.store.put_agent_run(
                run.run_id, session.session_id, run.model_dump(mode="json")
            )
            await self.store.put_post(
                post.post_id, session.session_id, post.model_dump(mode="json")
            )
            await self._save_evaluation(session, capture, evaluation, post=post)
            return ServiceResult(
                data=run.model_dump(mode="json"),
                status_code=202,
                execution_mode=evaluation_invocation.execution_mode,
            )

        return await self._idempotent(f"continue_agent_run:{run_id}", key, payload, action)

    async def get_agent_run(self, run_id: str) -> ServiceResult:
        payload = await self.store.get_agent_run(run_id)
        if payload is None:
            raise not_found("Agent run")
        return ServiceResult(data=payload, status_code=200, execution_mode=self.execution_mode)

    async def get_agent_trace(self, run_id: str) -> ServiceResult:
        run = await self.store.get_agent_run(run_id)
        if run is None:
            raise not_found("Agent run")
        return ServiceResult(
            data={
                "schema_version": "1.0",
                "agent_run": run,
                "skill_runs": await self.store.get_skill_runs(run_id),
            },
            status_code=200,
            execution_mode=self.execution_mode,
        )

    async def invoke_skill(self, skill_name: str, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            session = await self.require_session(str(payload["session_id"]))
            if skill_name == "content_composer" and (
                payload["input"].get("format") != "before_after_image"
            ):
                raise DomainError(
                    "SKILL_NOT_FOUND",
                    "W2 only supports before_after_image content jobs",
                    status_code=404,
                )
            skill = self.registry.get(skill_name, str(payload["skill_version"]))
            invocation = await skill.invoke(payload["input"])
            await self._persist_skill_invocation(invocation, session.session_id, None, 0)
            return ServiceResult(
                data={
                    "schema_version": "1.0",
                    "run": invocation.run.model_dump(mode="json"),
                    "output": invocation.output,
                },
                status_code=202,
                execution_mode=invocation.execution_mode,
            )

        return await self._idempotent(f"invoke_skill:{skill_name}", key, payload, action)

    async def create_capture(
        self, payload: JsonObject, key: str, claim_token: str | None = None
    ) -> ServiceResult:
        session_id = str(payload["session_id"])
        source_client = await self.capture_authorization.authorize_write(
            session_id, claim_token
        )

        async def action() -> ServiceResult:
            session = await self.require_session(session_id)
            if session.shot_plan is None:
                raise DomainError(
                    "INVALID_STATE", "ShotPlan is required before capture", status_code=409
                )
            allowed_states = {"shot_plan_ready", "coaching"}
            if source_client == "ios":
                allowed_states.add("handoff_ready")
            if session.state not in allowed_states:
                raise DomainError(
                    "INVALID_STATE",
                    "Capture requires a shot_plan_ready or coaching session",
                    status_code=409,
                )
            expected_round = len(session.capture_rounds) + 1
            if payload["round_index"] != expected_round or expected_round > 2:
                raise DomainError(
                    "INVALID_STATE",
                    f"round_index must be {expected_round} and at most 2",
                    status_code=409,
                )
            media_asset_id = str(payload["media_asset_id"])
            if not self._is_fixture_capture(session, media_asset_id):
                self._require_capture_upload_consent(session)
                await self._require_media(session, media_asset_id, "capture")
            frame = payload.get("frame_selection")
            if source_client == "ios" and not isinstance(frame, dict):
                raise DomainError(
                    "VALIDATION_FAILED",
                    "iOS Capture requires a selected local frame",
                    status_code=422,
                )
            capture = Capture(
                capture_id=new_id("cap"),
                session_id=session.session_id,
                round_index=expected_round,
                media_asset_id=media_asset_id,
                status="ready",
                source_client=source_client,
                capture_method=payload.get("capture_method") or session.shot_plan.capture_mode,
                selected_frame_id=(None if not isinstance(frame, dict) else frame["frame_id"]),
                selected_frame_timestamp_ms=(
                    None if not isinstance(frame, dict) else frame.get("timestamp_ms")
                ),
                selection_source=(
                    None if not isinstance(frame, dict) else frame["selection_source"]
                ),
                created_at=datetime.now(UTC),
            )
            await self.store.put_capture(
                capture.capture_id, session.session_id, capture.model_dump(mode="json")
            )
            updated = session.model_copy(
                update={
                    "state": "capturing",
                    "capture_rounds": [*session.capture_rounds, capture],
                    "updated_at": datetime.now(UTC),
                }
            )
            await self.store.put_session(session.session_id, updated.model_dump(mode="json"))
            await self._record_trusted_capture_event(
                updated,
                event_name="result_upload",
                client=source_client,
                round_index=expected_round,
                execution_mode="local_capture",
                source=str(capture.capture_method),
            )
            return ServiceResult(data=capture.model_dump(mode="json"), status_code=201)

        return await self._idempotent("create_capture", key, payload, action)

    async def get_capture(self, capture_id: str) -> ServiceResult:
        payload = await self.store.get_capture(capture_id)
        if payload is None:
            raise not_found("Capture")
        return ServiceResult(data=payload, status_code=200)

    async def select_frame(
        self,
        capture_id: str,
        payload: JsonObject,
        key: str,
        claim_token: str | None = None,
    ) -> ServiceResult:
        existing_payload = await self.store.get_capture(capture_id)
        if existing_payload is None:
            raise not_found("Capture")
        existing_capture = Capture.model_validate(existing_payload)
        await self.capture_authorization.authorize_write(
            existing_capture.session_id, claim_token
        )

        async def action() -> ServiceResult:
            capture_payload = await self.store.get_capture(capture_id)
            if capture_payload is None:
                raise not_found("Capture")
            capture = Capture.model_validate(capture_payload).model_copy(
                update={
                    "selected_frame_id": payload["frame_id"],
                    "selected_frame_timestamp_ms": payload.get("timestamp_ms"),
                    "selection_source": payload.get("selection_source"),
                    "status": "ready",
                }
            )
            session = await self.require_session(capture.session_id)
            if session.state != "capturing":
                raise DomainError(
                    "INVALID_STATE", "Frame selection requires capture state", status_code=409
                )
            rounds = [
                capture if item.capture_id == capture.capture_id else item
                for item in session.capture_rounds
            ]
            if all(item.capture_id != capture.capture_id for item in session.capture_rounds):
                raise DomainError(
                    "INVALID_STATE", "Capture is missing from Session", status_code=409
                )
            await self.store.put_capture(
                capture.capture_id, capture.session_id, capture.model_dump(mode="json")
            )
            updated = session.model_copy(
                update={"capture_rounds": rounds, "updated_at": datetime.now(UTC)}
            )
            await self.store.put_session(session.session_id, updated.model_dump(mode="json"))
            return ServiceResult(data=capture.model_dump(mode="json"), status_code=200)

        return await self._idempotent(f"select_frame:{capture_id}", key, payload, action)

    async def create_evaluation(
        self, payload: JsonObject, key: str, claim_token: str | None = None
    ) -> ServiceResult:
        session_id = str(payload["session_id"])
        await self.capture_authorization.authorize_write(session_id, claim_token)

        async def action() -> ServiceResult:
            session = await self.require_session(session_id)
            if not self._uses_fixture_evaluation(session):
                self._require_external_consent(session)
            capture = await self._require_latest_capture(session, str(payload["capture_id"]))
            evaluation, invocation = await self._evaluate(session, capture)
            await self._persist_skill_invocation(invocation, session.session_id, None, 0)
            await self._save_evaluation(session, capture, evaluation)
            await self._record_trusted_capture_event(
                session,
                event_name="result_evaluated",
                client=capture.source_client or "h5",
                round_index=capture.round_index,
                execution_mode=evaluation.execution_mode or invocation.execution_mode,
                source="selected_frame",
                latency_ms=invocation.run.latency_ms,
            )
            return ServiceResult(
                data=evaluation.model_dump(mode="json"),
                status_code=202,
                execution_mode=invocation.execution_mode,
            )

        return await self._idempotent("create_evaluation", key, payload, action)

    async def render_post(self, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            session = await self.require_session(str(payload["session_id"]))
            if payload["format"] != "before_after_image":
                raise DomainError(
                    "SKILL_NOT_FOUND",
                    "W2 only supports before_after_image content jobs",
                    status_code=404,
                )
            if session.evaluation is None or session.state not in {"coaching", "completed"}:
                raise DomainError("INVALID_STATE", "Evaluation is required first", status_code=409)
            invocation = await self.registry.get("content_composer").invoke(payload)
            post = PostJob.model_validate(invocation.output)
            await self._persist_skill_invocation(invocation, session.session_id, None, 0)
            await self.store.put_post(
                post.post_id, session.session_id, post.model_dump(mode="json")
            )
            updated = session.model_copy(
                update={"publish_package": post, "updated_at": datetime.now(UTC)}
            )
            await self.store.put_session(session.session_id, updated.model_dump(mode="json"))
            return ServiceResult(
                data=post.model_dump(mode="json"),
                status_code=202,
                execution_mode=invocation.execution_mode,
            )

        return await self._idempotent("render_post", key, payload, action)

    async def get_post(self, post_id: str) -> ServiceResult:
        payload = await self.store.get_post(post_id)
        if payload is None:
            raise not_found("Post")
        return ServiceResult(data=payload, status_code=200, execution_mode=self.execution_mode)

    async def put_events(self, payload: JsonObject, key: str) -> ServiceResult:
        async def action() -> ServiceResult:
            sanitized: list[JsonObject] = []
            raw_events = payload["events"]
            if not isinstance(raw_events, list):
                raise DomainError("VALIDATION_FAILED", "events must be an array", status_code=422)
            for raw in raw_events:
                if not isinstance(raw, dict):
                    raise DomainError(
                        "VALIDATION_FAILED", "event must be an object", status_code=422
                    )
                await self.require_session(str(raw["session_id"]))
                properties = raw.get("properties", {})
                if not isinstance(properties, dict):
                    raise DomainError(
                        "VALIDATION_FAILED", "properties must be an object", status_code=422
                    )
                lowered_keys = {str(name).lower() for name in properties}
                if any(
                    fragment in name
                    for name in lowered_keys
                    for fragment in self.FORBIDDEN_EVENT_FRAGMENTS
                ):
                    raise DomainError(
                        "VALIDATION_FAILED",
                        "Analytics properties contain a forbidden privacy field",
                        status_code=422,
                    )
                safe_properties = {
                    name: value
                    for name, value in properties.items()
                    if name in self.SAFE_EVENT_PROPERTIES
                    and isinstance(value, str | int | float | bool)
                }
                sanitized.append({**raw, "properties": safe_properties})
            accepted, duplicates = await self.store.put_events(sanitized)
            return ServiceResult(
                data={
                    "schema_version": "1.0",
                    "accepted_count": accepted,
                    "duplicate_count": duplicates,
                },
                status_code=202,
            )

        return await self._idempotent("put_events", key, payload, action)

    async def _active_analysis(self, session: SoloShotSession) -> ReferenceAnalysis:
        payload = await self.store.get_analysis_for_session(session.session_id)
        if payload is None:
            raise DomainError(
                "INVALID_STATE", "Active reference analysis is missing", status_code=409
            )
        analysis = ReferenceAnalysis.model_validate(payload)
        if (
            session.active_reference_analysis_id is not None
            and analysis.analysis_id != session.active_reference_analysis_id
        ):
            raise DomainError(
                "INVALID_STATE", "Active analysis snapshot is inconsistent", status_code=409
            )
        return analysis

    async def _require_media(
        self, session: SoloShotSession, media_asset_id: str, purpose: str
    ) -> MediaAsset:
        record = await self.store.get_media(media_asset_id)
        if record is None:
            raise not_found("Media")
        asset = MediaAsset.model_validate(record.asset)
        if asset.session_id != session.session_id:
            raise DomainError(
                "MEDIA_ACCESS_DENIED", "Media belongs to another Session", status_code=404
            )
        if asset.purpose != purpose:
            raise DomainError(
                "VALIDATION_FAILED", f"Media purpose must be {purpose}", status_code=422
            )
        if asset.status != "ready" or asset.expires_at <= datetime.now(UTC):
            raise DomainError(
                "MEDIA_NOT_READY",
                "Media is not ready or has expired",
                status_code=409,
                recoverable=True,
            )
        return asset

    async def _require_latest_capture(self, session: SoloShotSession, capture_id: str) -> Capture:
        capture_payload = await self.store.get_capture(capture_id)
        if capture_payload is None:
            raise not_found("Capture")
        capture = Capture.model_validate(capture_payload)
        if (
            capture.session_id != session.session_id
            or session.shot_plan is None
            or session.state != "capturing"
            or not session.capture_rounds
            or session.capture_rounds[-1].capture_id != capture.capture_id
        ):
            raise DomainError("INVALID_STATE", "Capture or ShotPlan mismatch", status_code=409)
        return capture

    async def _evaluate(
        self, session: SoloShotSession, capture: Capture
    ) -> tuple[ResultEvaluation, SkillInvocation]:
        if session.reference_asset is None or session.shot_plan is None:
            raise DomainError(
                "INVALID_STATE", "Reference and ShotPlan are required", status_code=409
            )
        analysis = await self._active_analysis(session)
        evaluating = session.model_copy(
            update={"state": "evaluating", "updated_at": datetime.now(UTC)}
        )
        await self.store.put_session(session.session_id, evaluating.model_dump(mode="json"))
        skill_input: JsonObject = {
                "reference_asset": session.reference_asset.model_dump(mode="json"),
                "reference_analysis": analysis.model_dump(mode="json"),
                "scene_asset_id": session.scene_asset_id,
                "capture": capture.model_dump(mode="json"),
                "shot_plan": session.shot_plan.model_dump(mode="json"),
                "mode": session.mode,
                "media_kind": "selected_frame",
                "round_index": capture.round_index,
            }
        if capture.round_index == 2 and session.evaluations:
            previous_capture = session.capture_rounds[-2]
            skill_input["previous_capture"] = previous_capture.model_dump(mode="json")
            skill_input["previous_evaluation"] = session.evaluations[-1].model_dump(mode="json")
        try:
            invocation = await self.registry.get("result_evaluation").invoke(skill_input)
        except Exception:
            restored = session.model_copy(
                update={"state": "capturing", "updated_at": datetime.now(UTC)}
            )
            await self.store.put_session(session.session_id, restored.model_dump(mode="json"))
            raise
        if invocation.output.get("issue_code") == "motion_timing_wrong":
            restored = session.model_copy(
                update={"state": "capturing", "updated_at": datetime.now(UTC)}
            )
            await self.store.put_session(session.session_id, restored.model_dump(mode="json"))
            raise DomainError(
                "COMPARE_FAILED",
                "A selected still frame cannot support motion timing conclusions",
                status_code=502,
                recoverable=True,
            )
        normalized_output = dict(invocation.output)
        issue_code = normalized_output.get("issue_code")
        if isinstance(issue_code, str):
            normalized_output["next_instruction"] = self._issue_instruction(issue_code)
        execution_mode = invocation.execution_mode
        normalized_output["execution_mode"] = (
            "fixture" if execution_mode == "mock" else execution_mode
        )
        evaluation = ResultEvaluation.model_validate(
            {
                **normalized_output,
                "evaluation_id": new_id("eval"),
                "capture_id": capture.capture_id,
            }
        )
        return evaluation, invocation

    async def _save_evaluation(
        self,
        session: SoloShotSession,
        capture: Capture,
        evaluation: ResultEvaluation,
        *,
        post: PostJob | None = None,
    ) -> None:
        await self.store.put_evaluation(
            evaluation.evaluation_id,
            session.session_id,
            capture.capture_id,
            evaluation.model_dump(mode="json"),
        )
        state = "completed" if evaluation.goal_satisfied or capture.round_index >= 2 else "coaching"
        updated = session.model_copy(
            update={
                "state": state,
                "evaluation": evaluation,
                "evaluations": [*session.evaluations, evaluation],
                "publish_package": post if post is not None else session.publish_package,
                "updated_at": datetime.now(UTC),
            }
        )
        await self.store.put_session(session.session_id, updated.model_dump(mode="json"))

    @staticmethod
    def _issue_instruction(issue_code: str) -> str:
        instructions = {
            "person_too_large": "后退两步，其他动作保持不变",
            "person_too_small": "向前一步，其他动作保持不变",
            "person_too_left": "向右移动一步，保持当前距离",
            "person_too_right": "向左移动一步，保持当前距离",
            "head_cut": "手机稍微向上调整，确保头部完整入镜",
            "feet_cut": "手机稍微向下调整，确保脚部完整入镜",
            "background_blocked": "侧移一步，露出参考中的背景主体",
            "pose_direction_wrong": "转向参考方向，保持人物位置不变",
            "arm_position_wrong": "只调整手臂，其他动作保持不变",
            "camera_too_high": "将手机降低一些，保持镜头水平",
            "camera_too_low": "将手机抬高一些，保持镜头水平",
            "camera_angle_wrong": "调平手机，其他位置保持不变",
        }
        instruction = instructions.get(issue_code)
        if instruction is None:
            raise DomainError(
                "COMPARE_FAILED",
                "Evaluation issue is unsupported for selected-frame coaching",
                status_code=502,
                recoverable=True,
            )
        return instruction

    @staticmethod
    def _require_external_consent(session: SoloShotSession) -> None:
        if session.external_ai_consent_at is None:
            raise DomainError(
                "CONSENT_REQUIRED",
                "External AI media analysis consent is required",
                status_code=409,
                recoverable=True,
            )

    @staticmethod
    def _require_capture_upload_consent(session: SoloShotSession) -> None:
        if (
            session.capture_upload_consent_at is None
            and session.external_ai_consent_at is None
        ):
            raise DomainError(
                "CONSENT_REQUIRED",
                "Temporary capture upload consent is required",
                status_code=409,
                recoverable=True,
            )

    @staticmethod
    def _uses_fixture_evaluation(session: SoloShotSession) -> bool:
        return (
            session.mode == "original_replication"
            and session.reference_asset is not None
            and session.reference_asset.source_type == "preset"
        )

    @staticmethod
    def _is_fixture_capture(session: SoloShotSession, media_asset_id: str) -> bool:
        return (
            session.mode == "original_replication"
            and session.reference_asset is not None
            and session.reference_asset.source_type == "preset"
            and media_asset_id.startswith("media_fixture_")
        )

    async def _persist_skill_invocation(
        self,
        invocation: SkillInvocation,
        session_id: str,
        run_id: str | None,
        position: int,
    ) -> None:
        await self.store.put_skill_run(
            invocation.run.skill_run_id,
            run_id,
            session_id,
            position,
            invocation.run.model_dump(mode="json"),
            invocation.output,
        )

    async def _record_trusted_capture_event(
        self,
        session: SoloShotSession,
        *,
        event_name: str,
        client: str,
        round_index: int,
        execution_mode: str,
        source: str,
        latency_ms: int | None = None,
    ) -> None:
        properties: JsonObject = {
            "mode": session.mode,
            "source": source,
            "execution_mode": execution_mode,
            "round_index": round_index,
        }
        if latency_ms is not None:
            properties["latency_ms"] = latency_ms
        await self.store.put_events(
            [
                {
                    "schema_version": "1.0",
                    "event_id": str(uuid4()),
                    "event_name": event_name,
                    "session_id": session.session_id,
                    "source_channel": session.source_channel,
                    "client": client,
                    "timestamp": datetime.now(UTC).isoformat(),
                    "properties": properties,
                }
            ]
        )
