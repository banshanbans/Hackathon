import { describe, expect, it } from "vitest";
import {
  cameraAngleLabel,
  cameraHeightLabel,
  captureModeLabel,
  creationModeLabels,
  executionModeLabels,
  lensLabel,
  poseLabel,
  productErrorCopy,
  roundLabel,
} from "./productCopy";

describe("产品文案映射", () => {
  it("将运行状态转换为可信的中文状态", () => {
    expect(executionModeLabels.fixture).toBe("演示模式");
    expect(executionModeLabels.live).toBe("实时分析");
    expect(executionModeLabels.fallback).toBe("稳妥模式");
    expect(executionModeLabels.error).toBe("需要重试");
  });

  it("不向用户暴露原始 ShotPlan 枚举", () => {
    expect(creationModeLabels.scene_adaptation).toBe("灵感迁移");
    expect(cameraHeightLabel("waist")).toBe("腰部高度");
    expect(cameraAngleLabel("level")).toBe("镜头水平");
    expect(lensLabel("1x")).toBe("1× 主摄");
    expect(captureModeLabel("photo")).toBe("拍照");
    expect(poseLabel("unknown_template")).toBe("专属构图");
    expect(roundLabel(1)).toBe("第一次");
    expect(roundLabel(2)).toBe("调整后");
  });

  it("将稳定错误码转换成可恢复的用户语言", () => {
    expect(productErrorCopy("PROVIDER_UNAVAILABLE").title).toBe("AI 摄影导演暂时离线");
    expect(productErrorCopy("PROVIDER_REJECTED").title).toBe("这张画面暂时没有分析完成");
    expect(productErrorCopy("HANDOFF_EXPIRED").title).toBe("任务码已过期");
    expect(productErrorCopy("UNKNOWN_CODE").detail).toBe("你的进度还在，请再试一次。");
  });
});
