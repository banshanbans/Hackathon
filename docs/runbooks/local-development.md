# 本地开发运行手册

## 首次设置

1. 在 macOS 上安装 Python 3.12、Node.js 24、Java 21 和 XcodeGen：`brew install python@3.12 node openjdk@21 xcodegen`。
2. 启动 Docker Desktop。
3. 运行 `make bootstrap` 和 `make generate`。
4. 将 `.env.example` 复制为 `.env`。首次运行 `make dev-infra` 时也会自动创建该文件。

## 启动 W2/W3 本地链路

依次运行：

```bash
make dev-infra
make migrate
make dev-api
make dev-h5
```

- API：`http://127.0.0.1:8000`
- H5：`http://127.0.0.1:5173`
- MinIO 控制台：`http://127.0.0.1:9001`

`make dev-infra` 会启动 PostgreSQL、Redis、MinIO，并创建私有的 `soloshot-media` 存储桶。`make migrate` 会应用 W1、W2 和 W3 迁移；应用启动时不会自动修改数据库结构。

## H5 MediaPipe 现场陪拍

H5 的 ShotPlan 页面保留三个出口：“在 iPhone 继续”为主入口，“浏览器免安装陪拍”为增强入口，“直接拍照或上传”为可靠后备。浏览器入口会按需加载 `@mediapipe/tasks-vision@0.10.35`，并从当前 H5 域名下载固定版本的 Pose Landmarker Lite 与 WASM；首屏 bundle 不包含 MediaPipe。

模型和运行时位于：

```text
apps/h5/public/models/mediapipe/pose-landmarker-lite-v1.task
apps/h5/public/models/mediapipe/model-manifest.json
apps/h5/public/mediapipe/0.10.35/wasm/
```

运行 `npm run assets:mediapipe --workspace @soloshot/h5` 会从已安装 npm 包同步 WASM，并校验模型 SHA-256；`npm run build` 会自动执行该检查。模型文件不由构建脚本在线下载，升级时应单独审核来源、版本、摘要、许可和浏览器矩阵，再提交新的版本化路径。生产 Nginx 对这些路径使用一年 immutable 缓存，对 SPA HTML 使用 `no-cache`，因此升级时不能覆盖旧版本 URL。

实时推理只处理本地相机帧。关键点、预览帧和未选候选不写入 API、analytics 或日志；连拍三张只在内存中排序，用户确认后将所选 JPEG 字节和稳定操作键写入 IndexedDB，再沿 `consent → upload ticket → signed PUT → complete → Capture → Evaluation` 恢复执行。短视频 ShotPlan 在 H5 当前明确使用照片降级，iOS 仍负责原生 6 秒视频、触觉、弱网本地陪拍和设备压力管理。

本地 `http://127.0.0.1` 可调用相机；其他设备必须通过 HTTPS 访问。验证时至少覆盖：

```bash
npm run typecheck --workspace @soloshot/h5
npm test --workspace @soloshot/h5
make e2e-h5
```

自动化覆盖模型/WASM 同源分发、Alignment 迟滞与稳定、坐标映射、MediaPipe 关键点适配、候选排序、WebKit IndexedDB 恢复和上传后两轮路由。自动化不能关闭真实手机验收：发布前仍需在 HTTPS 环境用目标 iPhone Safari 和 Android Chrome 检查首次模型下载、权限拒绝、多人、弱光、旋转、前后台、内存压力、第二轮恢复及文件上传降级。

## W3 接力配置与本地验证

- `HANDOFF_TTL_SECONDS=600` 控制任务码有效期；认领凭据和 iOS 本地缓存默认保留 24 小时。
- `HANDOFF_DISCOVERY_ENABLED=true` 开启线下活动的 iOS 首页任务发现；只返回未认领且未过期的安全 Handoff 预览，普通共享环境应保持关闭。
- `HANDOFF_SIGNING_SECRET` 用于 HMAC 签名。开发环境可使用示例值；任何非开发环境都必须替换为至少 32 字符的随机密钥，否则 API 拒绝启动。
- `PUBLIC_HANDOFF_BASE_URL` 决定 QR 内容。本地可使用 `http://127.0.0.1:5173/handoff`；共享测试环境必须使用 iPhone 可访问的 HTTPS 地址。
- PostgreSQL 保存状态和哈希，不保存原始 `management_token`、`claim_token`；Redis 负责查询与认领限流。测试/生产的 Redis 故障时认领失败关闭，不绕过保护。
- H5 的管理 token 和创建 Idempotency-Key 仅存在于 `sessionStorage`，不会进入 URL、`localStorage`、analytics 或日志。

在 H5 生成 ShotPlan 后选择“在 iPhone 继续”。模拟器可用下列命令验证严格深链入口，任务码必须来自当前测试 Session：

```bash
xcrun simctl openurl booted 'soloshot://handoff/ABC234'
```

iOS Debug 和 Release 构建默认访问 `https://shotapi.socialdog.cn`。需要连接本机 API 时，应通过 `SOLOSHOT_API_BASE_URL=http://<Mac局域网IP>:8000` 覆盖；真机不能使用 `127.0.0.1` 访问 Mac。H5 的 `PUBLIC_HANDOFF_BASE_URL` 必须指向同一套可访问环境。

## W4 本地对齐与 Simulator Fixture

W4 从已缓存的 `ImportedTask` v3 进入“拍摄前准备”，使用后置广角主摄、固定 1×、竖屏 720p 预览和设备内 Vision。v3 在本地保存参考 `selected_box` 和版本化轮廓派生文件；旧 v1/v2 可读取但会回退构图辅助。生产 Overlay 显示参考人物虚线、实时人物实线与软性 Dice 轮廓接近度；该分数不控制自动拍摄。相机帧、实时蒙版和轮廓坐标不会保存、上传或发送给模型；W4 也不会申请麦克风或照片权限。

Simulator 没有真实后置相机。Debug 构建可通过以下启动参数进入明确标记的 Fixture 流程；Release 构建不能启用这些参数：

```text
-W4SeedTask
-W4FixtureCamera
-W4FixtureScenario ready
```

正常 Fixture 会依次模拟无人、多人、偏移和完全重合；IoU 达到 80%并稳定 1.2 秒后留在相机页自动倒数三秒。将 `ready` 改为 `auto_cancel` 可验证倒计时中 IoU 低于 70%后取消并重新触发；改为 `manual` 可验证连续五秒没有可用人体结果后的二次手动确认。增加 `-W4FixturePermissionDenied` 可验证权限拒绝恢复。推荐直接运行：

```bash
make test-ios
make e2e-ios-w4
```

`make test-ios` 会运行 W3/W4/W5 单元测试并构建通用 Simulator 目标；`make e2e-ios-w4` 会验证 80%自动触发、70%取消重试、未验证手动降级和权限拒绝四条 UI 路径。可通过 `IOS_SIMULATOR_NAME='iPhone 17 Pro'` 覆盖默认设备名。

部分 Simulator runtime 可能不包含 `VNDetectHumanBodyPoseRequest` 的系统模型权重。此时真实图片 Vision smoke 会明确显示为 skipped；Vision 关节过滤与坐标转换、AlignmentEngine 和 Overlay 测试仍必须通过。只有真机结果才能关闭真实 Vision 能力验收。

## W5 录制、候选帧、评价与第二轮

W5 从 W4 的自动对齐状态继续使用同一个 Camera Session，不经过独立 ready 或动作确认页。`photo` 模式在三秒倒计时后进行三张短间隔连拍；`short_video` 模式在倒计时后录制 6 秒、720p、后置 1×、无声 MOV，并在设备内抽取最多六张候选。视频失败、空间不足或关键系统压力会明确提供照片降级；用户选择降级后需重新完成对齐，再自动连拍。

候选帧按完整入镜、目标位置、人物比例、清晰度和受控姿势规则进行确定性本地推荐。未知姿势模板不会被猜测；用户可以选择任意候选。确认后会删除源视频和未选候选，只在明确同意后上传所选 JPEG。应用不申请麦克风或照片库权限，也不会上传预览帧、Vision 坐标或原始视频。

iOS 接力写请求必须携带 Keychain 中的 `X-Handoff-Claim-Token`。本地 Outbox 按 `consent → upload ticket → signed PUT → complete → create Capture → evaluate` 顺序执行，稳定保存 Capture/Evaluation Idempotency-Key；上传地址过期时只重建 upload attempt。冷启动会恢复待处理工作，网络请求的真实结果决定是否进入离线待重试状态。

Simulator 使用 Release 无法启用的 Debug Fixture：

```text
-W4SeedTask
-W4FixtureCamera
-W4FixtureScenario ready
-W5FixtureShortVideo
```

增加 `-W5FixtureVideoFailure` 可验证视频失败后的照片降级。运行：

```bash
make e2e-ios-w5
make e2e-w5
```

预设任务即使关联真实拍摄照片，评价仍显示“Fixture 固定评分”，不能描述为模型比较或 AI 已验证改善。自定义参考和场景适配必须配置 Ark 并获得 External AI 同意；未配置时保持可重试待评价并返回 `PROVIDER_UNAVAILABLE`，不会切换为 Fixture。

## Fixture 与 Live 的边界

默认配置是 `MODEL_PROVIDER=hybrid`、`MOCK_AI_ENABLED=false`：

- 预设参考 + 原图复刻走确定性 Fixture，页面和响应头均标记 `Fixture`，不会产生模型费用。
- 自定义参考以及所有场景适配走火山方舟 Live。首次创建 Live Session 前，用户必须勾选“媒体将发送至火山方舟分析”。
- Live 需要在 `.env` 中填写 `ARK_API_KEY` 和 `ARK_MODEL_ID`。缺少配置时返回可恢复的 `PROVIDER_UNAVAILABLE`，不会静默切换为 Fixture。
- `ARK_BASE_URL` 默认使用 `https://ark.cn-beijing.volces.com/api/v3`，模型 ID 不写入代码。
- `SCENE_ADAPTATION_TIMEOUT_SECONDS=35` 是现场视觉推理的硬超时。现场模式随后由 `shooting_plan@1.1.0` 服务端规则生成 ShotPlan，不再次读取图片或调用 Ark；原图复刻仍使用 `shooting_plan@1.0.0` 模型路径。

真实 Live smoke test 会产生外部模型调用和可能的费用，因此不属于默认 CI。仅在确认凭据和费用后手动填写 `.env`，再从 H5 选择自定义参考执行完整流程。

## 媒体规则与恢复

- H5 会将所有用户图片归一化为 JPEG，最长边不超过 1280px，并按 0.82、0.78、0.75 质量逐级尝试；仍超出 2MB 时继续等比缩小。API 继续兼容最长边 2048px、最大 8MB 的既有上限。
- 视频只在浏览器内暂停并抽取 JPEG 帧，不上传原视频；限制为 30 秒和 100MB。
- 上传地址有效 10 分钟，预览地址有效 5 分钟，媒体默认保留 24 小时。
- API 每小时清理过期媒体；删除 Session 会立即清理其媒体和关联记录。
- 刷新后以服务端 Session 为准恢复路由、ShotPlan 和两轮评价。现场图已上传时会恢复 `sceneAssetId`、阶段和稳定操作键，并继续未完成的适配或规则生成；尚未上传的本地文件不能跨刷新恢复。
- localStorage 只保存 Session ID、路由草稿和非敏感选项，不保存媒体、Base64 或签名 URL。
- 浏览器现场陪拍只在用户确认候选后将这一张 JPEG 的字节写入 IndexedDB，用于刷新恢复；评价完成后立即删除。

## 完整验证

```bash
make generate
make lint
make typecheck
make test
make test-api-integration
make evals
make e2e-h5
make test-ios
make e2e-handoff
make e2e-ios-w4
make e2e-ios-w5
make e2e-w5
```

- `make test`：API 单元测试、合同测试、H5 单元测试和生产构建。
- `make test-api-integration`：应用迁移并验证 PostgreSQL 跨实例恢复与级联删除，需要本地基础设施已启动。
- `make test-contracts`：验证 OpenAPI/JSON Schema，以及 H5、Python、Swift 生成类型。
- `make evals`：运行五个版本化 Skill 的固定评测，不调用付费模型。
- `make e2e-h5`：运行移动 Chromium、移动 WebKit 和桌面 Chromium 的 W2/W3 流程。
- `make test-ios`：运行 W3/W4/W5 XCTest target，并构建通用 iOS Simulator 目标；可用 `IOS_SIMULATOR_NAME` 覆盖本机设备名。
- `make e2e-handoff`：运行 W3 API 生命周期/并发/限流测试和 H5 模拟 iOS 认领的接力 Playwright 场景。
- `make e2e-ios-w4`：运行 W4 Debug Fixture 的三条 Simulator UI 自动化；Fixture 页面和结果页都会持续标识演示来源。
- `make e2e-ios-w5`：运行 W5 Debug Fixture 的照片、短视频、视频失败降级、两轮评价和离线恢复 Simulator UI 自动化。
- `make e2e-w5`：组合运行 W5 API 规则、H5 跨端状态恢复和 W5 iOS Simulator UI 门禁。

## 常见问题恢复

- Docker 连接失败：启动 Docker Desktop，然后重新运行 `make dev-infra`。
- Live 返回 `PROVIDER_UNAVAILABLE`：确认 `MODEL_PROVIDER=hybrid`，并检查 `ARK_API_KEY`、`ARK_MODEL_ID` 是否只存在于服务端 `.env`。
- 上传失败：确认 MinIO 健康、存储桶已初始化，并检查浏览器访问地址是否与 `OBJECT_STORAGE_PUBLIC_ENDPOINT` 一致。
- 媒体已过期：重新开始 Session；过期签名 URL 不应保存或复用。
- 端口冲突：停止占用 5173、8000、9000、5432 或 6379 的本地进程，不要临时修改共享契约 URL。
- 生成代码与契约不一致：运行 `make generate`，并同时提交契约和生成产物；不要手工编辑 `generated/`。
- 数据库提示缺少关系：先运行 `make migrate`，不要让应用启动时自动建表。
- Playwright 缺少浏览器：运行 `npx playwright install chromium webkit` 后重试。
- Xcode 缺少 iOS 平台组件：在 Xcode 的“设置 > Components”中安装对应平台；仅出现 SDK 不代表平台已完成注册。
- iPhone 无法打开二维码：确认二维码为手机可访问的 HTTPS 地址，落地页再由用户点击 `soloshot://handoff/{code}`；本地 `127.0.0.1` 只适用于同机模拟器。
- 接力返回 `HANDOFF_RATE_LIMITED`：等待 `Retry-After` 后重试，并检查 Redis 健康；不要关闭限流绕过。
- W4 相机权限被拒绝：从错误页打开系统设置，授权后返回准备页，由用户主动重新进入相机。
- W4 显示设备压力过高：Critical 时 Vision 会暂停；先退出降温，或使用二次确认的手动降级，不能把手动结果视作已验证。
- W4 发生相机中断或媒体服务重置：恢复后必须由用户点击继续或返回准备页重进，应用不会在后台静默重启相机。
- W5 显示“等待网络”：确认 API、MinIO 与网络可用后点击重试；应用冷启动会恢复 Outbox，但不宣称系统终止后仍能在后台上传。
- W5 上传地址过期：Outbox 会创建新的 upload attempt；Capture 与 Evaluation 的 Idempotency-Key 不会改变。
- W5 Live 返回 `PROVIDER_UNAVAILABLE`：候选 JPEG 和工作状态会保留到 24 小时任务过期，可在 Ark 配置恢复后重试；不得用 Fixture 分数替代。

W2 已完成本地和 CI 工程验收。W3 的代码、本地和 CI 验收不等于最终关闭：还必须在 HTTPS 测试环境用指定 iPhone 连续完成真机清单。W4/W5 只完成本地、CI 和 Simulator 工程范围；真实后置相机、弱光、热压力、前后台、中断、5–8 秒录制、候选处理时延、断网恢复和两轮成功率仍需指定 iPhone 验收。真实 Ark 效果还需要独立的付费 smoke 与样本验收。
