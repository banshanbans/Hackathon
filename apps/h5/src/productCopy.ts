import type { ExecutionMode } from "./apiClient";

export const executionModeLabels: Readonly<Record<ExecutionMode, string>> = {
  fixture: "演示模式",
  mock: "演示模式",
  live: "实时分析",
  cache: "已恢复",
  fallback: "稳妥模式",
  error: "需要重试",
};

export const creationModeLabels = {
  original_replication: "原图复刻",
  scene_adaptation: "灵感迁移",
} as const;

const cameraHeightLabels: Readonly<Record<string, string>> = {
  ground: "贴近地面",
  knee: "膝盖高度",
  waist: "腰部高度",
  chest: "胸口高度",
  eye: "视线高度",
  overhead: "高于头顶",
};

const cameraAngleLabels: Readonly<Record<string, string>> = {
  level: "镜头水平",
  slight_up: "轻微仰拍",
  slight_down: "轻微俯拍",
};

const lensLabels: Readonly<Record<string, string>> = {
  "0.5x": "0.5× 超广角",
  "1x": "1× 主摄",
  "2x": "2× 长焦",
};

const captureModeLabels: Readonly<Record<string, string>> = {
  photo: "拍照",
  short_video: "短视频",
};

const poseLabels: Readonly<Record<string, string>> = {
  standing_coffee_full_body: "门廊光影",
  wall_lean_three_quarter: "山城回望",
  profile_bottle_closeup: "街角侧影",
  seated_drink: "咖啡馆午后",
};

export function cameraHeightLabel(value: string): string {
  return cameraHeightLabels[value] ?? "专属高度";
}

export function cameraAngleLabel(value: string): string {
  return cameraAngleLabels[value] ?? "专属角度";
}

export function lensLabel(value: string): string {
  return lensLabels[value] ?? "推荐镜头";
}

export function captureModeLabel(value: string): string {
  return captureModeLabels[value] ?? "推荐方式";
}

export function poseLabel(value: string): string {
  return poseLabels[value] ?? "专属构图";
}

export function roundLabel(round: number): string {
  return round === 1 ? "第一次" : "调整后";
}

export type ProductErrorCopy = {
  title: string;
  detail: string;
};

const errorCopyByCode: Readonly<Record<string, ProductErrorCopy>> = {
  CONSENT_REQUIRED: {
    title: "还需要你的同意",
    detail: "确认后，SoloShot 才会开始分析这份素材。",
  },
  MEDIA_NOT_READY: {
    title: "这张素材需要重新选择",
    detail: "重新加入画面后，就能从这里继续。",
  },
  MEDIA_TOO_LARGE: {
    title: "这份素材有点大",
    detail: "换一张照片或更短的视频再试一次。",
  },
  UNSUPPORTED_MEDIA: {
    title: "这份素材暂时无法使用",
    detail: "换一张照片或短视频再试一次。",
  },
  REFERENCE_NO_PERSON: {
    title: "没有找到清晰的主角",
    detail: "重新圈选人物，或换一张画面再试。",
  },
  REFERENCE_MULTIPLE_PEOPLE: {
    title: "画面里出现了多位人物",
    detail: "只圈出你想复刻的主角。",
  },
  PROVIDER_UNAVAILABLE: {
    title: "AI 摄影导演暂时离线",
    detail: "你的进度还在，稍后再试一次。",
  },
  MODEL_TIMEOUT: {
    title: "AI 摄影导演还在路上",
    detail: "你的进度还在，请再试一次。",
  },
  NETWORK_ERROR: {
    title: "暂时没有连上 SoloShot",
    detail: "检查网络后再试一次。",
  },
  CAPTURE_UPLOAD_FAILED: {
    title: "这张照片还没传上去",
    detail: "照片仍在本机，可以重新提交。",
  },
  UPLOAD_CANCELED: {
    title: "上传已取消",
    detail: "画面仍在本机，准备好后可以继续。",
  },
  HANDOFF_EXPIRED: {
    title: "任务码已过期",
    detail: "重新生成一个任务码即可继续。",
  },
  HANDOFF_REVOKED: {
    title: "这次接力已取消",
    detail: "你可以重新生成任务码。",
  },
  HANDOFF_ALREADY_CLAIMED: {
    title: "ShotPlan 已被另一台 iPhone 接收",
    detail: "回到原来的设备继续，或重新创建任务。",
  },
  UNSAFE_INSTRUCTION: {
    title: "这个拍法不够安全",
    detail: "换一个更稳妥的位置再继续。",
  },
  SESSION_EXPIRED: {
    title: "这次旅拍任务已经结束",
    detail: "回到首页开始一次新的创作。",
  },
  NOT_FOUND: {
    title: "这次旅拍任务已经结束",
    detail: "回到首页开始一次新的创作。",
  },
  INVALID_STATE: {
    title: "这一步需要重新开始",
    detail: "回到上一步，就能继续完成作品。",
  },
};

export function productErrorCopy(code: string): ProductErrorCopy {
  return (
    errorCopyByCode[code] ?? {
      title: "这一步没有完成",
      detail: "你的进度还在，请再试一次。",
    }
  );
}
