# W5 iOS 录制、评价与第二轮状态报告

## 结论

W5 已完成代码、合同、API/H5/iOS 测试、Simulator build 和 Debug Fixture 自动化范围。链路从 W4 对齐完成进入受控动作提示与三秒倒计时，支持三张照片连拍或 5–8 秒无声短视频、本地候选推荐、用户确认单张 JPEG、明确上传与 External AI 同意、评价、唯一复拍建议、第二轮重新对齐，以及 iOS/H5 两端结果恢复。

W5 尚不能标记为最终关闭。Simulator 不能证明真实后置相机录制稳定性、AVAssetWriter 性能、真实 Vision 候选质量、热压力与中断恢复；当前也没有配置真实 Ark 凭据。因此状态为“本地/CI/Simulator 完成，指定 iPhone 与真实 Ark 验收未关闭”。

## 合同与服务端

- 新增 `POST /api/v1/sessions/{session_id}/capture-consent`，分开记录候选 JPEG 上传同意与 External AI 同意。
- iOS Capture 写路径复用 W3 Claim Token。未接力 H5 保持兼容；接力未完成时拒绝拍摄写入；接力完成后必须验证绑定设备、Session 和有效期。
- `Capture` 增加 `source_client`、`capture_method`、`selected_frame_timestamp_ms` 和 `selection_source`；iOS 创建 Capture 时必须携带 `FrameSelection`。
- `ResultEvaluation` 持久化原始 `execution_mode`。预设原图复刻始终为 `fixture`；自定义与场景适配为 `live`，Provider 不可用时返回可恢复错误，绝不静默降级。
- 只有 `media_fixture_` 前缀可以绕过真实媒体校验；普通 `media_` 必须完成归属、MIME、魔数、SHA-256 和尺寸验证。
- Session/Capture 的轮次规则阻止并发创建相同轮次、重复评价和第一轮未完成时开始第二轮。Provider 失败会将 Session 从 `evaluating` 恢复到本轮可重试状态。
- `result_evaluation@1.1.0` 在第二轮加入前一轮 Capture/Evaluation；单帧输入禁止输出 `motion_timing_wrong`。模型结果先经 schema 校验，再由固定 IssueCode 映射生成唯一受控指令。
- `result_upload` 与 `result_evaluated` 只记录客户端、轮次、模式、执行模式和时延，不记录 token、Frame ID、媒体地址、路径或画面。

## iOS 本地采集与恢复

- W4 ready 后保留同一 Camera Session。倒计时期间失去已确认对齐会取消倒计时并重新对齐；`manual` 必须二次确认并持续标记为未经 Vision 验证。
- 照片模式进行三张短间隔连拍；短视频模式使用后置 1×、720p、H.264、无声 MOV。视频失败、空间不足或 Critical pressure 会明确提供照片降级。
- 视频候选至少间隔 400ms，并覆盖动作开始、中段和结束。推荐分数由完整入镜 30%、位置轮廓 25%、人物比例 20%、清晰度 15%、受控姿势 10% 组成；未知姿势会重新归一化其余权重。
- `CaptureWorkStore` 原子保存两个 Round、候选选择、同意状态、稳定 Idempotency-Key 和网络步骤。源视频及未选候选在确认后删除，所选 JPEG 使用完整文件保护并随任务在 24 小时内清理。
- Outbox 严格按 consent、upload ticket、signed PUT、complete、create Capture、evaluate 顺序推进。签名 URL 不落盘；Claim Token 只从 Keychain 读取，不进入任务 JSON、日志或 analytics。
- 第一轮满足目标可直接结束；否则只展示一个问题和一条受控重拍指令。第二轮重新执行 setup、alignment 和 capture，并在评价后始终进入最终结果，不增加第三轮。

## 用户可见行为

- ready 页可以进入动作提示和非纯音频三秒倒计时；屏幕文字始终存在，语音只使用本地固定短句。
- 候选页明确显示“本地推荐”和原因，用户可选择任意候选，不展示身体评分。
- 同意页说明只上传所选 JPEG；原视频、未选候选、预览帧和 Vision 坐标不上传。
- 预设任务可展示真实 Round 图片，但评分卡始终标注“Fixture 固定评分”，不声称 AI 比较或真实改善。
- 自定义 Live 展示真实两轮图片、readiness、执行模式和唯一问题；Ark 未配置时停留在可重试状态。
- H5 Handoff 页面会显示 `handoff_ready`、`capturing`、`evaluating`、`coaching` 和 `completed`，完成后可恢复两轮结果。

## 验证范围

最终门禁命令：

```bash
make generate
make lint
make typecheck
make test
make test-contracts
make test-api-integration
make evals
make e2e-h5
make test-ios
make e2e-handoff
make e2e-ios-w4
make e2e-ios-w5
make e2e-w5
git diff --check
```

自动测试覆盖 Claim Token 与同意门禁、真实/Fixture 媒体边界、两轮顺序与幂等、Provider 恢复、1.1 多模态输入、敏感字段过滤、候选评分与间隔、工作存储、上传 URL 过期、冷启动恢复、照片/短视频/降级 UI 流程，以及 H5 跨端轮询和刷新恢复。

## 真机与真实 Ark 缺口

- 需要指定 iPhone 验证真实三张连拍、5–8 秒无声视频、候选抽取、JPEG 方向与尺寸、低存储、前后台、来电中断、媒体服务重置、Serious/Critical pressure 和弱光。
- 至少连续执行十次两轮流程，记录录制、候选处理、上传和评价 p50/p95、成功率、失败阶段、设备与系统版本。
- 飞行模式选择候选后需要验证前台恢复上传；iOS 被系统杀死后只承诺冷启动恢复，不承诺后台继续上传。
- 真实 Ark 需要用户确认凭据和费用后执行独立 smoke，并用自定义参考实拍样本评估输出质量；Fixture 不可用于证明模型效果或“第二轮可见改善”。

## 下一最小工作包

执行“W4/W5 指定 iPhone + 真实 Ark 验收”小包：先用 HTTPS 测试环境完成十次真实接力、对齐、录制、候选、断网恢复和两轮结果，再在明确授权付费后补充少量自定义 Live smoke。通过前不进入 W6 的分享与内容增长扩展。
