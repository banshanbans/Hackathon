import type { InstructionCode } from "../domain/alignmentModels";

export const instructionCopy: Readonly<Record<InstructionCode, string>> = {
  no_person: "走进画面，我在等你",
  multiple_people: "请只保留一位主角",
  move_left: "很好，再向左一点",
  move_right: "不错，再向右一点",
  move_forward: "靠近一点，就快好了",
  move_backward: "后退一点，留出更多风景",
  feet_outside: "再退一点，让脚也进入画面",
  head_outside: "稍微调整，让头部完整入镜",
  adjust_body_direction: "很好，把肩膀再转一点",
  adjust_arm: "动作很接近，再调整一下手臂",
  hold_still: "非常好，保持不动",
  ready_to_capture: "位置很好，准备拍摄",
};
