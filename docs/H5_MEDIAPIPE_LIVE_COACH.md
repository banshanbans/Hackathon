# H5 MediaPipe 现场陪拍方案与验收

## 结论与产品边界

SoloShot 保留 iOS App 作为主力现场陪拍产品。H5 增加一条免安装的 MediaPipe 路径，让没有安装 App 的用户也能完成“ShotPlan → 现场指导 → 自动拍摄 → 本地选片 → 第一次评价 → 单问题复拍 → 第二次评价 → 结果”的完整旅程。

这不是 iOS 能力迁移。iOS 继续拥有 AVFoundation、Vision、原生轮廓、触觉、短视频、弱网陪拍、后台恢复和设备压力管理。H5 只承诺 P0 照片闭环，并始终保留文件上传后备。

## 用户流程

ShotPlan 页面提供三个明确入口：

1. “在 iPhone 继续”：主入口，进入现有 Handoff。
2. “浏览器免安装陪拍”：加载本地模型，进入现场陪拍。
3. “直接拍照或上传”：任何设备都可使用的可靠后备。

浏览器现场陪拍先检查 HTTPS、`getUserMedia` 与模型初始化。成功后使用后置相机和本地 Pose Landmarker，每次只展示一条受控中文指令。达到 80% 构图重合并稳定 1.2 秒后倒计时三秒；低于 70% 会取消倒计时。连续五秒无法得到可信人体结果时，允许用户二次确认“已安全就位”，并将完成模式标记为 `manual`，不能声称已经过姿态验证。

倒计时结束后连拍三张 JPEG。候选只在本地按完整入镜、目标位置、人物比例、清晰度和受控动作排序。用户可覆盖本地推荐；未选候选随即释放。只有所选 JPEG 会在明确提示后进入既有上传和评价链路。第二轮沿用相同浏览器路径，只执行服务端返回的一条核心调整建议。

## 技术结构

```text
React 路由与页面
  → CameraController / Canvas Overlay / SpeechController
  → CoachRuntime（自适应 8/5/3/2 Hz）
  → MediaPipeAdapter
  → AlignmentEngine（与 iOS 共享语义）
  → CandidateScoring
  → IndexedDB CaptureDraft
  → 现有 Consent / Media / Capture / Evaluation API
```

运行时使用动态 `import()`，因此 MediaPipe 不进入 H5 首屏主 bundle。当前固定版本如下：

- npm runtime：`@mediapipe/tasks-vision@0.10.35`
- model：`MediaPipe Pose Landmarker Lite float16 v1`
- model SHA-256：`59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a`
- model path：`/models/mediapipe/pose-landmarker-lite-v1.task`
- WASM path：`/mediapipe/0.10.35/wasm/`
- source manifest：`/models/mediapipe/model-manifest.json`

模型和 WASM 均由 SoloShot H5 同源服务器提供，不依赖运行时 CDN。MediaPipe 项目和 npm package 声明 Apache-2.0；升级必须保留第三方许可、官方来源和新摘要，不能在原 URL 上替换文件。

## 状态与恢复

H5 不保存相机预览或关键点。连拍候选仅存在于内存；用户确认后，所选 JPEG 以 `ArrayBuffer + MIME` 写入 IndexedDB，以避开 WebKit 对 `Blob` 直接持久化的兼容问题。

草稿同时保存 `uploadCreateKey`、`uploadCompleteKey`、`captureKey`、`evaluationKey`、`networkStep`、`mediaAssetId` 和 `captureId`。刷新后从最后成功步骤继续。上传票据失败且尚未形成媒体资产时，只轮换本次 upload attempt 的键；Capture 和 Evaluation 的稳定键不改变，避免重试产生重复写入。完成评价后删除草稿。

## 隐私和诚实行为

- 姿态推理在设备内执行；不向 SoloShot API 上传关键点、预览帧或未选候选。
- 只有用户最终确认的一张 JPEG 进入对象存储和评价。
- analytics 只记录安全枚举、轮次、延迟和错误码，不记录媒体、坐标、签名 URL 或 token。
- 当前固定 Web runtime 的模型预热自动化未观察到第三方 CDN 请求；发布前仍须在真实相机推理期间检查 Network，因为 [Google 的 MediaPipe 总体隐私说明](https://github.com/google-ai-edge/mediapipe#privacy)提示部分 Tasks SDK 可能发送性能或使用指标。若目标浏览器版本发生第三方指标请求，必须先补充用户披露和所需同意，不能仅以“自托管”掩盖。
- 预设原图复刻仍显示 Fixture 固定评分，即使用户现场拍摄了真实照片，也不能描述为 AI 已比较改善。
- 自定义参考和场景适配仍需要 External AI 同意；缺少 Live provider 时不能静默换成 Fixture。
- 不做人脸身份识别、吸引力或身体评分，不指导用户站到道路、轨道、悬崖边或不稳定支撑物上。

## 部署与缓存

`apps/h5/nginx.conf` 对 `/models/` 和 `/mediapipe/` 使用 `try_files ... =404`，避免不存在的二进制被 SPA HTML 接管；WASM 返回 `application/wasm`。版本化资产缓存一年并标记 `immutable`，HTML 使用 `no-cache`。构建前脚本会复制 npm runtime 的 WASM 并验证模型摘要；任何校验失败都会中止构建。

发布前应确认 H5 容器包含模型、manifest 和全部 WASM，外部 HTTPS 请求能直接返回这些文件，并观察首次下载的流量、耗时和失败率。生产服务器无需额外模型服务或 GPU；模型由浏览器下载并在用户设备执行。

## 验收清单

自动化门禁：

- Alignment 正常、边界、迟滞、稳定和手动降级测试通过；
- MediaPipe 33 点到领域关键点、人物框和置信度映射测试通过；
- aspect-fill 坐标测试通过；
- 三张候选确定性排序测试通过；
- 移动 Chromium、移动 WebKit 和桌面 Chromium 的入口、上传后备、IndexedDB 恢复与完整既有 H5 流程通过；
- OpenAPI 生成、合同测试、API consent/capture/evaluation 测试通过；
- H5 生产构建与 Nginx 二进制缓存配置通过。

发布前人工设备门禁：

- iPhone Safari 与 Android Chrome 在生产 HTTPS 首次下载和二次缓存均可初始化；
- 权限拒绝、无相机、不安全上下文和模型失败均能回到文件上传；
- 单人、多人、头脚出框、弱光、横竖屏变化和性能降频提示符合预期；
- 倒计时取消、二次手动确认、三张选片、刷新恢复和两轮评价都可完成；
- Network 面板没有关键点、预览帧、未选候选、token 或签名 URL 进入 analytics/log；
- iOS 主入口、Handoff 和原生陪拍没有回归。

## 当前不在 H5 P0 范围

- 浏览器短视频录制与视频候选抽帧；当前明确使用照片降级。
- 与 iOS 等价的触觉、后台任务、离线陪拍、热压力与相机中断恢复。
- Web Worker 推理和 Service Worker 模型离线包；当前通过自适应检测频率和 HTTP immutable 缓存控制性能。
- 复杂动作和世界坐标评分；未知动作只做构图判断，不猜测动作完成度。
