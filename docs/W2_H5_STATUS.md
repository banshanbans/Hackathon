# W2 H5 端到端状态报告

## Summary

W2 已形成一条无需登录、可在本地和 CI 运行的 H5 纵向链路：参考选择与真实圈选、约束和 Live 同意、参考理解、可选现场适配、ShotPlan、最多两轮拍摄评价、结果展示和刷新恢复。

预设原图复刻明确使用 `Fixture`；自定义媒体及所有场景适配明确使用火山方舟 `Live`。未配置方舟凭据时 Live 返回 `PROVIDER_UNAVAILABLE`，不会伪装为成功或静默降级。当前状态不包含公网部署。

## Files changed

- `packages/contracts/`：媒体生命周期、Session 兼容字段、参考安全状态、场景适配和事件批处理合同，以及 H5、Python、Swift 生成客户端。
- `services/api/`：MinIO/S3 兼容存储、媒体校验与清理、W2 数据迁移、方舟 Responses Provider、混合路由、场景适配 Skill、两轮评价和 analytics。
- `packages/prompts/scene_adaptation/1.0.0/`：版本化 prompt、schema、manifest 和 eval case。
- `apps/h5/`：路由化向导、圈选坐标、图片/视频预处理、上传与重试、恢复、两轮结果、事件队列、组件测试和 Playwright 测试。
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

2026-07-17 本地结果：

- `make generate`：H5、Python、Swift 客户端生成成功。
- `make lint`：Ruff（API 与迁移）和 H5 严格 TypeScript 检查通过。
- `make typecheck`：Mypy 37 个文件和 H5 project references 检查通过。
- `make test`：API 单元测试 24/24、合同测试 13/13、H5 合同测试 1/1、H5 单元/组件测试 10/10、Swift Fixture 解码 1/1，H5 生产构建成功。
- `make test-api-integration`：PostgreSQL 迁移、跨实例恢复、复合参考归属、并发写入和级联删除 1/1 通过。
- `make evals`：五个 Skill bundle 与 Test Image 数据集评测 5/5 通过。
- `make e2e-h5`：移动 Chromium、移动 WebKit、桌面 Chromium 共 12/12 通过。
- `xcodebuild` 通用 iOS Simulator 构建成功；首次沙箱运行无法访问 CoreSimulatorService，授权访问后同一构建通过。

默认测试和 eval 使用 Fixture、Mock SDK 或规则输入，不产生付费方舟请求。真实 Live smoke test 必须由持有凭据的人显式执行。

## User-visible behavior

- `/` 选择原图复刻或场景适配，并选择预设或自定义参考。
- `/reference` 对预设、图片或视频抽帧进行真实拖动、缩放和重置圈选。
- `/constraints` 设置拍摄约束；Live 路径要求明确勾选外部 AI 媒体同意。
- Session 路由展示分析、现场适配、ShotPlan、两轮拍摄与评价、最终结果，并在刷新后从服务端恢复。
- 预设 Fixture 只展示评分变化卡，不伪造 Before/After 图片。
- 自定义 Live 结果展示当前 Session 的 Round 1 / Round 2 上传和 readiness 变化。
- 页面持续显示 `Fixture`、`Live`、`Fallback` 或 `Error`，错误可重试且不会被伪装为成功。

## Known risks or device-only gaps

- 尚未运行带真实 `ARK_API_KEY`、真实模型 ID 和真实账单的 Live smoke test；CI 只覆盖 Mock SDK 与 Live API mock。
- 尚未部署公开 URL，因此公网 CORS、TLS、对象存储公网域名和线上清理任务仍需部署验收。
- 移动 WebKit 自动化不能代替真实 iOS Safari 和 Android Chrome 的相机权限、相册选择、视频解码、内存压力和弱网验证。
- H5 没有 iOS 的实时 Vision 对齐能力，这是已接受的产品边界。
- W3 的二维码接力、任务码、分享和 iOS 导入未进入 W2。

## Next smallest recommended work package

进入 W3 前，先做一个最小部署准备切片：配置测试环境的 PostgreSQL、私有对象存储、TLS/CORS 和方舟凭据，执行一次受控 Live smoke test，并在两台真实移动设备上记录媒体选择、上传、刷新和两轮评价结果。通过后开始 W3 Handoff 合同与短期任务码实现。
