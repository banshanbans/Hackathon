# W2 H5 端到端状态报告

## Summary

W2 已形成一条无需登录、可在本地和 CI 运行的 H5 纵向链路：参考选择与真实圈选、约束和 Live 同意、参考理解、现场适配、ShotPlan、最多两轮拍摄评价、结果展示和刷新恢复。

现场适配现在只执行一次 `scene_adaptation@1.0.0` 视觉推理；`shooting_plan@1.1.0` 根据已返回的布局、受控姿势类别和安全状态在服务端确定性生成，不读取媒体，也不访问 Ark。原图复刻继续使用既有 `shooting_plan@1.0.0` 模型路径，公开 DTO 和接口顺序未改变。

预设原图复刻明确使用 `Fixture`；自定义媒体及所有场景适配明确使用火山方舟 `Live`。未配置方舟凭据时 Live 返回 `PROVIDER_UNAVAILABLE`，不会伪装为成功或静默降级。当前状态不包含公网部署。

## Files changed

- `packages/contracts/`：媒体生命周期、Session 兼容字段、参考安全状态、场景适配和事件批处理合同，以及 H5、Python、Swift 生成客户端。
- `services/api/`：MinIO/S3 兼容存储、媒体校验与清理、W2 数据迁移、方舟 Responses Provider、混合路由、场景适配 Skill、两轮评价和 analytics。
- `services/api/app/domain/shot_plan_rules.py` 与 `services/api/app/providers/rules.py`：现场适配的纯规则 ShotPlan、受控动作模板、安全门禁和零成本 trace。
- `packages/prompts/scene_adaptation/1.0.0/`：版本化 prompt、schema、manifest 和 eval case。
- `apps/h5/`：1280px/2MB 图片预处理、选图即上传、三段真实状态、现场图布局覆盖、刷新恢复、桌面三图对比、移动横向切换、组件测试和 Playwright 测试。
- `apps/ios/`：第一轮“参考图 vs 第一拍”及就绪度、最终“参考 / 第一拍 / 调整后”分页画廊和对应测试。
- `.env.example` 与 `docs/`：本地配置、隐私边界、设计 QA 和验收说明。

## Validation commands and results

最终验收命令为：

```bash
make generate
make lint
make typecheck
make test
make test-api-integration
make evals
make e2e-h5
make test-ios
```

2026-07-22 本次变更的本地结果：

- `make lint`：Ruff（API 与迁移）和 H5 严格 TypeScript 检查通过。
- `make typecheck`：API Mypy 与 H5 project references 检查通过。
- `make test`：API 单元测试 43/43、合同测试 14/14、H5 合同测试 1/1、H5 单元/组件测试 25/25、Swift 生成合同测试 1/1，H5 生产构建成功。
- API eval、contract 与 integration 相关测试：19 个通过；2 个需要本地 PostgreSQL 的用例按环境条件跳过。
- `make evals`：5/5 通过，不调用付费模型。
- `make e2e-h5`：移动 Chromium、移动 WebKit、桌面 Chromium 共 24/24 通过，覆盖自动现场适配、阶段状态、上传重试和响应式三图对比。
- `SoloShotTests` 全量通过；`W5CaptureUITests` 通过，测试过程同时完成 iOS Simulator 构建。
- `git diff --check`：通过。

默认测试和 eval 使用 Fixture、Mock SDK 或规则输入，不产生付费方舟请求。真实 Live smoke test 必须由持有凭据的人显式执行。

## User-visible behavior

- `/` 选择原图复刻或场景适配，并选择预设或自定义参考。
- `/reference` 对预设、图片或视频抽帧进行真实拖动、缩放和重置圈选。
- `/constraints` 设置拍摄约束；Live 路径要求明确勾选外部 AI 媒体同意。
- Session 路由展示分析、现场适配、ShotPlan、两轮拍摄与评价、最终结果，并在刷新后从服务端恢复。
- 现场页选图后自动执行“上传 → 人物与构图识别 → 服务端规则生成”；上传阶段显示真实百分比，模型与规则阶段只显示真实阶段状态。
- 现场图在等待和失败时持续显示；取得 `target_layout` 后叠加人物框、头部点、脚底线和方向提示，ShotPlan 页继续使用同一现场图。
- H5 图片最长边限制为 1280px，按 JPEG 0.82、0.78、0.75 逐级编码，仍超出 2MB 时继续等比缩小；自然小图不会放大。
- 预设 Fixture 只展示评分变化卡，不伪造 Before/After 图片。
- 有真实图片的最终结果在桌面并排展示“参考 / 第一拍 / 第二拍”，移动端使用横向吸附；缺图时保持诚实占位或现有 Fixture 说明。
- 页面持续显示 `Fixture`、`Live`、`Fallback` 或 `Error`，错误可重试且不会被伪装为成功。

## Known risks or device-only gaps

- 尚未运行带真实 `ARK_API_KEY`、真实模型 ID 和真实账单的 Live smoke test；CI 只覆盖 Mock SDK 与 Live API mock。
- 因未执行真实 Ark smoke，`scene_adaptation` 的 10–30 秒目标和线上规则阶段端到端低于 1 秒仍需带真实凭据测量；纯规则单元测试已验证低于 1 秒。
- 尚未部署公开 URL，因此公网 CORS、TLS、对象存储公网域名和线上清理任务仍需部署验收。
- 移动 WebKit 自动化不能代替真实 iOS Safari 和 Android Chrome 的相机权限、相册选择、视频解码、内存压力和弱网验证。
- H5 没有 iOS 的实时 Vision 对齐能力，这是已接受的产品边界。

## Next smallest recommended work package

执行一个受控验收切片：在明确授权凭据和费用后运行一次 `MOCK_AI_ENABLED=false` Live 流程，确认每次现场适配只有一个 Ark 请求、模型与规则阶段真实时延、幂等重试和无敏感日志；随后在指定 iPhone 与真实移动浏览器上验证图片方向、弱网恢复和三图切换。
