# W4 iOS 本地实时对齐状态报告

## 结论

W4 已完成代码、本地测试、Simulator build 和 Debug Fixture UI 自动化范围：用户可从 W3 缓存任务摘要进入拍摄前准备，授权后打开后置 1× 竖屏相机，在设备内使用 Vision 人体姿态、参考人物轮廓、实时人物轮廓、统一坐标映射和原生 2D Overlay 获得单条受控中文指令，并以 `verified`、`compositionOnly` 或 `manual` 三种诚实等级结束对齐。

W4 尚不能标记为最终关闭。Simulator 不能验证真实后置相机、Vision 系统模型、弱光、发热、通知中断和真机延迟；这些项目必须由指定 iPhone 的真机小包完成。

## 实现范围

- `ImportedTask` 升级为缓存 schema v2，保存 `captureMode`、`targetLayout` 和 `iosAlignmentSupported`；v1 缓存仍可查看摘要，但不能开启陪拍。
- `CameraEngine` 在专用队列配置 `AVCaptureSession`，使用后置广角主摄、固定 1×、720p 和竖屏预览。`CMSampleBuffer` 只在回调内使用，跨边界仅发布可发送的领域数据。
- `VisionEngine` 使用 `VNDetectHumanBodyPoseRequest`，集中完成关节置信度过滤与左下角到左上角领域坐标转换。参考图另用人物实例蒙版选中 `selected_box` 内目标，实时相机使用快速人物分割；所有像素和蒙版都只在设备内短暂存在。
- `CoordinateMapper` 统一处理旋转、`aspect-fill` 裁切、点和矩形映射；目标轮廓与人物观测复用同一管线。
- `AlignmentEngine` 在归一化相机坐标中计算人物框与目标框的 IoU；达到 80% 后连续稳定 1.2 秒并完成三样本确认才进入自动倒计时。倒计时使用 70% 退出阈值，并继续检查无人、多人、头脚完整度、大小、左右和姿势。
- 未知 `pose_template` 不做字符串猜测，构图稳定后只返回 `compositionOnly`；`manual` 必须二次确认并明确标记为未经 Vision 验证。
- 生产 Overlay 优先显示参考人物橙色虚线、实时人物青色实线、动作说明、唯一指令和 Dice“轮廓接近度”；该分数是软评分，不参与 80%/70%构图门槛。参考轮廓失败时诚实回退目标框、头部圆和脚底线；Debug Overlay 可显示关节、人物框、`aspect-fill` 图像区域、FPS、延迟、置信度与构图 IoU，但不记录像素、坐标、媒体路径或任务凭据。
- `ImportedTask v3` 缓存 `selected_box`、轮廓文件和提取状态；轮廓资产带算法版本与参考图 SHA-256，并与任务、参考图一起过期和删除。v1/v2 缓存继续可读取并回退原有构图辅助。
- 正常压力下实时轮廓目标 6–10Hz，Serious 降为 3–5Hz；连续 300ms 没有新轮廓即隐藏旧线，Critical 暂停 Vision 并保留明确的手动降级。
- 语音与触觉默认开启，屏幕文字始终存在；VoiceOver 开启时改用可访问状态通知，避免与语音合成重叠。
- 系统 pressure 或 thermal state 为 Serious 时降至 5Hz，Critical 时暂停 Vision 并提供明确手动降级。相机中断结束后由用户点击继续；媒体服务重置要求返回准备页重进。
- 自动触发逻辑不修改 OpenAPI、不增加网络实时循环，也不保存或上传预览帧；倒计时与 W5 本地拍摄复用同一个 Camera Session。

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

iOS 单元测试覆盖 AlignmentEngine 的指令优先级、80% IoU 进入边界、70% 倒计时退出边界、稳定计时重置、三样本确认、连续五秒手动降级、受控模板与未知模板降级；同时覆盖坐标旋转与裁切、Overlay 同源映射、反馈冷却、缓存 v1/v2、权限错误状态、thermal/system pressure 合并策略和 Vision 关节转换。

当前本机 iOS 26.3 Simulator 缺少 Apple Vision 人体姿态模型权重，因此有人/无人真实图片 smoke 明确标记为 skipped；纯 Vision→领域转换测试仍是强制通过项。该跳过不能作为真实 Vision 已验证的证据。

`make e2e-ios-w4` 使用 Release 无法启用的 Debug Fixture，覆盖：

1. 任务摘要 → 准备 → 无人 → 多人 → 偏移 → 80% 稳定 → 自动三秒倒计时。
2. 倒计时中跌破 70% → 取消 → 重新完成 80% + 1.2 秒 → 再次自动触发。
3. 连续五秒无人 → “手动已就位” → 二次确认 → `manual` 自动倒计时且保持未验证标记。
4. 权限拒绝 → 可恢复相机错误 → 返回准备页。

## 用户可见行为

- W3 任务摘要中的“开始现场陪拍”已启用；旧 v1 任务会提示重新导入。
- 准备页显示后置 1×、竖屏、机位、安全提示、固定手机确认，以及语音/触觉开关。非 1× ShotPlan 会明确说明 W4 降级使用 1×。
- 对齐页显示真实相机或明确的 Fixture 背景、双人物轮廓、动作说明、唯一指令、软评分、参考图缩略图和可访问文字反馈。多人、分割丢失、参考提取失败和热压力均显示明确状态。
- 不再经过独立 ready/动作确认页；达到 80%并稳定后留在相机页自动倒数。Fixture 与 `manual` 结果继续明确标记来源或未验证等级。

## 真机缺口与风险

- 需要在 A16 及以上指定 iPhone 上验证竖屏后置 1×、Vision 人体姿态、参考实例蒙版、实时人物分割、正常状态至少 6Hz 轮廓更新、300ms 旧线隐藏、80%/70%边界抖动、弱光、无人/多人/单人、前后台、通知中断、媒体服务重置、发热和至少十次完整自动触发。
- 需要记录指令反馈 p50/p95、端到端 frame-to-publish 延迟和二十秒内就位成功率；Simulator 数据不能用于宣称真机达到 500ms。
- 简化姿势只支持受控本地模板目录，不做人脸身份、吸引力或身体评分。遮挡、宽松衣物和复杂姿势可能降级为 `compositionOnly`。
- W3 仍有独立的 HTTPS 测试环境与真机接力验收缺口；若真实 Handoff 尚未关闭，W4 真机任务可先用受控本地导入，但不能据此关闭 W3。

## 下一最小工作包

将 W4 与已实现的 W5 合并为指定 iPhone 真机验收小包：安装开发构建，完成真实相机、Vision、弱光、中断、热压力、录制、候选帧、断网恢复和十次两轮流程，记录设备/系统版本、p50/p95 与失败原因。
