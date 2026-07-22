from __future__ import annotations

from dataclasses import dataclass

from app.domain.errors import DomainError
from app.domain.models import ReferenceAnalysis, ShotPlan, UserConstraints

RULE_PROVIDER_NAME = "server-rules-v1"
RULE_SKILL_VERSION = "1.1.0"


@dataclass(frozen=True)
class ShotPlanRuleResult:
    plan: ShotPlan
    warnings: list[str]


def build_scene_adaptation_plan(
    analysis: ReferenceAnalysis,
    constraints: UserConstraints,
    *,
    plan_id: str,
) -> ShotPlanRuleResult:
    """Build a safe, deterministic plan without reading media or free-form notes."""

    if analysis.safety_status == "block":
        raise DomainError(
            "UNSAFE_INSTRUCTION",
            "Scene analysis blocks generation of a shooting plan",
            status_code=422,
            recoverable=True,
        )

    layout = analysis.target_layout
    pose_family = _pose_family(layout.pose_template)
    motion = pose_family == "motion"
    camera_height = (
        "chest"
        if pose_family in {"seated", "closeup"} or layout.height >= 0.72
        else "waist"
    )
    horizontal = _horizontal_region(layout.center_x)
    scale_instruction = _scale_instruction(layout.height)
    support = (
        "使用三脚架或稳定夹具"
        if constraints.tripod_available
        else "将手机竖直固定在不会滑落的稳定支撑物上"
    )
    luggage_note = "，行李放在取景范围外且不阻挡通道" if constraints.has_luggage else ""
    setup_instruction = (
        f"{support}，镜头保持水平；人物站在画面{horizontal}，{scale_instruction}{luggage_note}。"
    )

    action_script = [
        {
            "sequence": 1,
            "instruction": f"进入画面{horizontal}的目标轮廓，调整距离直到人物大小贴合。",
            "duration_seconds": 3,
        },
        {
            "sequence": 2,
            "instruction": _pose_instruction(pose_family, layout.body_direction),
            "duration_seconds": 3 if motion else 2,
        },
    ]

    safety_notes = _safety_notes(analysis, constraints)
    warnings = ["DETERMINISTIC_SCENE_SHOT_PLAN"]
    if analysis.safety_status == "warn":
        warnings.append("SCENE_SAFETY_WARNING_PROPAGATED")

    plan = ShotPlan.model_validate(
        {
            "schema_version": "1.0",
            "plan_id": plan_id,
            "camera_height": camera_height,
            "camera_angle": "level",
            "lens": "1x",
            "capture_mode": "short_video" if motion else "photo",
            "phone_setup_instruction": setup_instruction,
            "target_layout": layout.model_dump(mode="json"),
            "action_script": action_script,
            "safety_notes": safety_notes,
            "h5_execution": {
                "supported": True,
                "instruction": "保持现场图预览，按目标轮廓完成静态构图后提交成片。",
                "requires_realtime_alignment": False,
            },
            "ios_execution": {
                "supported": True,
                "instruction": "使用本地 Vision 与屏幕空间轮廓进行实时对齐。",
                "requires_realtime_alignment": True,
            },
            "confidence": min(analysis.confidence, 0.95),
        }
    )
    return ShotPlanRuleResult(plan=plan, warnings=warnings)


def _pose_family(pose_template: str) -> str:
    tokens = {token for token in pose_template.lower().replace("-", "_").split("_") if token}
    if tokens & {"walk", "walking", "turn", "turning", "run", "running"}:
        return "motion"
    if tokens & {"sit", "sitting", "seated", "chair", "bench"}:
        return "seated"
    if tokens & {"closeup", "close", "portrait", "headshot", "profile"}:
        return "closeup"
    if tokens & {"stand", "standing", "fullbody", "full", "lean", "leaning"}:
        return "standing"
    return "unknown"


def _horizontal_region(center_x: float) -> str:
    if center_x < 0.4:
        return "左侧"
    if center_x > 0.6:
        return "右侧"
    return "中央"


def _scale_instruction(height: float) -> str:
    if height >= 0.72:
        return "让人物占画面约四分之三"
    if height <= 0.5:
        return "保留更多环境，让人物占画面约一半"
    return "让人物占画面约三分之二"


def _pose_instruction(pose_family: str, body_direction: str) -> str:
    direction = {
        "front": "正对镜头",
        "back": "背向镜头",
        "left": "身体转向画面左侧",
        "right": "身体转向画面右侧",
        "slightly_left": "身体微微转向画面左侧",
        "slightly_right": "身体微微转向画面右侧",
    }[body_direction]
    if pose_family == "motion":
        return f"{direction}，按目标方向缓慢移动或转身，动作结束时停稳。"
    if pose_family == "seated":
        return f"保持坐姿稳定，{direction}，双脚和头部都留在轮廓内。"
    if pose_family == "closeup":
        return f"{direction}，肩膀放松并保持头部位置稳定。"
    if pose_family == "standing":
        return f"站稳并{direction}，保持自然姿势直到拍摄完成。"
    return f"站稳并{direction}，按屏幕轮廓保持自然姿势。"


def _safety_notes(
    analysis: ReferenceAnalysis, constraints: UserConstraints
) -> list[str]:
    notes: list[str] = []
    if analysis.safety_status == "warn":
        notes.extend(analysis.safety_warnings)
    notes.append("只在平整、允许停留且远离车辆的区域拍摄。")
    notes.append("确认手机支撑稳定，不会滑落或阻挡公共通道。")
    if constraints.has_luggage:
        notes.append("行李必须放在视线内且不能成为绊倒风险。")
    return list(dict.fromkeys(notes))[:10]
