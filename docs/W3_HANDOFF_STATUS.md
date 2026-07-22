# W3 跨端 Handoff 状态报告

## Summary

W3 已实现本地/CI 工程范围的 H5 → iPhone ShotPlan 接力：H5 创建十分钟任务码和真实可解码 QR，iOS 在安全公开预览后原子认领同一 Session/ShotPlan，将 app-owned 任务 JSON 原子写入 Application Support，并在断网或冷启动时恢复二十四小时任务摘要。

该状态不能标记为最终完成。W3 的最终 Definition of Done 还要求 HTTPS 测试环境和指定 iPhone 真机验收；当前仓库无法替代外部部署、系统相机和飞行模式真机记录。

## Files changed

- `packages/contracts/`：安全公开 Handoff 视图、创建/认领响应、稳定错误码和重新生成的 TypeScript、Python、Swift 客户端。
- `services/api/app/handoff/`、`services/api/app/application/handoff.py`：HMAC capability、Redis 限流、纯 application service 和领域状态转换。
- `services/api/app/persistence/`、`infra/migrations/`：Handoff PostgreSQL 表、事务行锁、级联删除和过期清理。
- `apps/h5/`：ShotPlan 双分支、QR/六位码、倒计时、刷新恢复、撤销重建、安全落地页和轮询状态。
- `apps/ios/`：深链解析、网络 actor、Keychain、原子任务缓存、离线恢复、参考图异步缓存和任务摘要。
- `services/api/tests/`、`apps/h5/tests/`、`apps/ios/SoloShotTests/`：合同、并发、限流、隐私、QR 解码、Playwright 和 XCTest 覆盖。

## Validation commands and results

已完成的最终验证：

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
git diff --check
```

- `make generate`：通过；TypeScript、Python、Swift 合同客户端已重新生成。
- `make lint`：通过；Python `ruff` 和 H5 ESLint 无错误。
- `make typecheck`：通过；Python `mypy` 检查 43 个源文件，H5 strict TypeScript 通过。
- `make test` / `make test-contracts`：通过；API unit 28/28、合同 14/14、H5 unit 14/14、H5/Python/Swift 生成合同测试及 H5 production build 均通过。
- `make test-api-integration`：通过；PostgreSQL 迁移、W1 路径及 W3 并发认领/级联删除 2/2 通过。
- `make evals`：通过；5/5。
- `make e2e-h5`：通过；移动 Chromium、移动 WebKit、桌面 Chromium 共 15/15。
- `make e2e-handoff`：通过；W3 后端领域测试 4/4，Handoff Playwright 3/3。
- `make test-ios`：通过；XCTest 6/6，iPhone Simulator build 成功。
- `xcrun simctl openurl ... soloshot://handoff/ABC234`：通过；App 安装到 iPhone 17 Pro Simulator 后成功接受严格深链。
- `git diff --check`：通过。

默认测试只使用 Fixture、Mock 或本地基础设施，没有产生火山方舟费用。上述结果关闭本地/CI 工程验收，但不替代 HTTPS 环境和指定 iPhone 真机验收。

## User-visible behavior

- ShotPlan 页面提供“在 iPhone 继续”和“留在网页拍摄”两个真实分支。
- H5 接力页显示可解码 QR、六位码、十分钟倒计时、复制、撤销、重新生成、失败重试及认领/缓存完成状态。
- HTTPS 落地页只展示模式、状态和有效期，由用户点击后打开 `soloshot://handoff/{code}`；二维码不携带 Session、媒体地址或 token。
- iOS 支持深链、粘贴和手输六位码，先显示安全预览，再由用户确认认领。
- 认领成功后立即持久化同一 `plan_id` 的机位、动作和安全提示；参考图失败不会伪造图片或阻塞 ShotPlan。
- W3 摘要中的原生拍摄按钮明确禁用并标注 W4，不提供假相机。

## 2026-07-22 iOS 接力入口增量

- iOS 生产启动现在固定进入接力首页，不再自动跳进最后一个任务；首页优先列出服务端仍有效且状态为 `created` 的任务，评委点击卡片即可一键认领，同时保留六位任务码入口和本机恢复列表。
- 本机任务索引兼容原有 `imported-task.json`，按导入时间倒序展示；删除或过期只清理对应任务和参考派生文件，不会误删其他任务。
- ShotPlan、准备、候选、同意、上传、复盘和结果等标准页面，以及对齐/倒计时/录制全屏页面，左上角均可返回首页。返回时会取消当前操作并停止相机会话，但保留已持久化的任务与拍摄进度。
- 服务端发现接口由 `HANDOFF_DISCOVERY_ENABLED` 显式控制，仅用于当事人已同意的线下活动。响应复用 `HandoffTask` 安全预览，不包含 `session_id`、媒体地址、管理凭据或 claim token；已认领、撤销、完成和过期任务不会返回。

## Known risks or device-only gaps

- 尚未配置 iPhone 可访问的 HTTPS H5/API 测试环境，系统相机扫描和 TLS/CORS 尚未验收。
- 尚未在指定 iPhone 连续执行十次、记录五秒内导入延迟、杀进程飞行模式恢复及第二台设备冲突。
- Simulator `onOpenURL` 和自动化测试不能替代 iOS 系统相机到 HTTPS 落地页再到自定义 scheme 的真机行为。
- Universal Links、AASA、Associated Domains、正式签名和分发配置留到正式分发准备；W3 使用系统相机 + HTTPS 落地页 + 自定义 URL scheme。
- W4 的 AVFoundation、Vision、Overlay、语音和触觉未进入本轮。

## Next smallest recommended work package

先完成一个“W3 部署与真机验收”小包：部署 HTTPS H5/API、设置随机签名密钥和 Redis/PostgreSQL，给指定 iPhone 安装开发构建，执行十次扫码/手输/离线恢复/冲突矩阵并记录延迟。通过后再开始 W4 相机、Vision 与 2D Overlay。
