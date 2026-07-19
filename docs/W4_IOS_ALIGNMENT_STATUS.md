# W4 iOS 本地实时对齐状态报告

## 结论

W4 已完成代码、本地测试、Simulator build 和 Debug Fixture UI 自动化范围：用户可从 W3 缓存任务摘要进入拍摄前准备，授权后打开后置 1× 竖屏相机，在设备内使用 Vision 人体姿态、统一坐标映射和原生 2D Overlay 获得单条受控中文指令，并以 `verified`、`compositionOnly` 或 `manual` 三种诚实等级结束对齐。

W4 尚不能标记为最终关闭。Simulator 不能验证真实后置相机、Vision 系统模型、弱光、发热、通知中断和真机延迟；这些项目必须由指定 iPhone 的真机小包完成。

## 实现范围

- `ImportedTask` 升级为缓存 schema v2，保存 `captureMode`、`targetLayout` 和 `iosAlignmentSupported`；v1 缓存仍可查看摘要，但不能开启陪拍。
- `CameraEngine` 在专用队列配置 `AVCaptureSession`，使用后置广角主摄、固定 1×、720p 和竖屏预览。`CMSampleBuffer` 只在回调内使用，跨边界仅发布可发送的领域数据。
- `VisionEngine` 使用 `VNDetectHumanBodyPoseRequest`，集中完成关节置信度过滤与左下角到左上角领域坐标转换。
- `CoordinateMapper` 统一处理旋转、`aspect-fill` 裁切、点和矩形映射；目标轮廓与人物观测复用同一管线。
- `AlignmentEngine` 实现无人、多人、头脚完整度、大小、左右、身体方向、基础手臂、稳定和 ready 的固定优先级；阈值、迟滞、三样本确认、1.2 秒稳定、连续五秒手动降级与两秒语音冷却均来自可注入配置。
- 未知 `pose_template` 不做字符串猜测，构图稳定后只返回 `compositionOnly`；`manual` 必须二次确认并明确标记为未经 Vision 验证。
- 生产 Overlay 只显示目标轮廓、头部圆、脚底线、唯一指令和稳定进度；Debug Overlay 可显示关节、人物框、`aspect-fill` 图像区域、FPS、延迟与置信度，但不记录像素、坐标、媒体路径或任务凭据。
- 语音与触觉默认开启，屏幕文字始终存在；VoiceOver 开启时改用可访问状态通知，避免与语音合成重叠。
- 系统 pressure 或 thermal state 为 Serious 时降至 5Hz，Critical 时暂停 Vision 并提供明确手动降级。相机中断结束后由用户点击继续；媒体服务重置要求返回准备页重进。
- W4 不修改 OpenAPI、不增加网络实时循环、不保存或上传预览帧，也不实现倒计时、快门、录制、候选帧或评价。

## 验证范围

最终门禁命令：

```bash
make generate
make lint
make typecheck
make test
make test-contracts
make evals
make e2e-h5
make test-ios
make e2e-handoff
make e2e-ios-w4
git diff --check
```

iOS 单元测试覆盖 AlignmentEngine 的指令优先级、进入/退出迟滞、三样本确认、1.2 秒 ready、连续五秒手动降级、受控模板与未知模板降级；同时覆盖坐标旋转与裁切、Overlay 同源映射、反馈冷却、缓存 v1/v2、权限错误状态、thermal/system pressure 合并策略和 Vision 关节转换。

当前本机 iOS 26.3 Simulator 缺少 Apple Vision 人体姿态模型权重，因此有人/无人真实图片 smoke 明确标记为 skipped；纯 Vision→领域转换测试仍是强制通过项。该跳过不能作为真实 Vision 已验证的证据。

`make e2e-ios-w4` 使用 Release 无法启用的 Debug Fixture，覆盖：

1. 任务摘要 → 准备 → 无人 → 多人 → 偏移 → 稳定 → `verified` ready。
2. 连续五秒无人 → “手动已就位” → 二次确认 → `manual` 未验证结果。
3. 权限拒绝 → 可恢复相机错误 → 返回准备页。

## 用户可见行为

- W3 任务摘要中的“开始现场陪拍”已启用；旧 v1 任务会提示重新导入。
- 准备页显示后置 1×、竖屏、机位、安全提示、固定手机确认，以及语音/触觉开关。非 1× ShotPlan 会明确说明 W4 降级使用 1×。
- 对齐页显示真实相机或明确的 Fixture 背景、目标 Overlay、唯一指令、稳定进度、参考图缩略图和可访问文字反馈。
- ready 页显示验证等级；Fixture 结果继续标记“Fixture 演示结果”。W5 已在后续实现中启用真实录制分支，W4 本身的对齐判定和诚实降级边界保持不变。

## 真机缺口与风险

- 需要在指定 iPhone 上验证竖屏后置 1×、Vision 人体姿态、目标轮廓重合、弱光、无人/多人/单人、前后台、通知中断、媒体服务重置、发热和至少十次完整对齐。
- 需要记录指令反馈 p50/p95、端到端 frame-to-publish 延迟和二十秒内就位成功率；Simulator 数据不能用于宣称真机达到 500ms。
- 简化姿势只支持受控本地模板目录，不做人脸身份、吸引力或身体评分。遮挡、宽松衣物和复杂姿势可能降级为 `compositionOnly`。
- W3 仍有独立的 HTTPS 测试环境与真机接力验收缺口；若真实 Handoff 尚未关闭，W4 真机任务可先用受控本地导入，但不能据此关闭 W3。

## 下一最小工作包

将 W4 与已实现的 W5 合并为指定 iPhone 真机验收小包：安装开发构建，完成真实相机、Vision、弱光、中断、热压力、录制、候选帧、断网恢复和十次两轮流程，记录设备/系统版本、p50/p95 与失败原因。
