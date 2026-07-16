# SoloShot AI｜Codex 工程实现规格

> **版本**：V3.0 Split Edition  
> **主要执行者**：Codex 及工程成员  
> **目标**：把产品方案转换为可以逐工作包实施、测试和验收的代码库  
> **先读**：仓库根目录 `AGENTS.md`  
> **产品背景**：`PRODUCT_OWNER_GUIDE.md`

---

## 1. 工程目标与不可妥协约束

构建一套“一核双端”的端到端产品：

- H5 可以通过公开链接完成参考镜头圈选、任务生成、成片评价和分享；
- iOS 可以读取同一任务，在指定 iPhone 上用 AVFoundation、Vision 和原生 2D Overlay 实时陪拍；
- Agent 根据意图编排版本化 Skills；
- 后端统一管理 Session、媒体、调用轨迹、成本、埋点和跨端接力；
- 至少一条真实主路径从参考图一直运行到第二次成片和内容输出。

### 不可妥协

1. **端到端优先**：任何阶段都必须保留可运行主路径。
2. **契约优先**：OpenAPI/JSON Schema 是 H5、iOS、后端的共同事实来源。
3. **实时本地化**：iOS 高频对齐循环不得依赖网络或 LLM。
4. **受控输出**：实时指导只能从枚举和规则映射生成，不能直接播放模型自由文本。
5. **真实与 Mock 分离**：Mock 必须通过显式配置开启，UI 和日志要标记；不可冒充真实运行。
6. **双端能力分层**：H5 负责低门槛和增长，iOS 负责实时设备能力，不追求功能镜像。
7. **可观察**：所有 Agent/Skill 调用必须记录版本、耗时、成本、置信度、fallback 和错误。
8. **可删除**：用户会话和临时媒体必须支持删除。
9. **不虚构平台接入**：未验证的抖音正式发布、账号和 POI 能力只能放在 adapter/preview 层。
10. **首版不用复杂 3D AR**：先交付固定机位下的 2D 屏幕坐标 Overlay。

---

## 2. 建议 Monorepo 结构

```text
.
├── AGENTS.md
├── README.md
├── PRODUCT_OWNER_GUIDE.md
├── CODEX_IMPLEMENTATION_SPEC.md
├── Makefile
├── .env.example
├── apps/
│   ├── h5/                         # React + TypeScript + Vite
│   │   ├── src/
│   │   │   ├── app/
│   │   │   ├── features/
│   │   │   │   ├── reference/
│   │   │   │   ├── agent-run/
│   │   │   │   ├── shot-plan/
│   │   │   │   ├── capture/
│   │   │   │   ├── evaluation/
│   │   │   │   ├── handoff/
│   │   │   │   ├── sharing/
│   │   │   │   └── creator-template/
│   │   │   ├── components/
│   │   │   ├── lib/
│   │   │   └── generated/          # generated API client/types
│   │   └── tests/
│   └── ios/
│       ├── SoloShot/
│       │   ├── App/
│       │   ├── Domain/
│       │   ├── Networking/
│       │   ├── Camera/
│       │   ├── Vision/
│       │   ├── Alignment/
│       │   ├── Overlay/
│       │   ├── Capture/
│       │   ├── SpeechHaptics/
│       │   ├── Features/
│       │   └── Generated/           # generated Codable contracts
│       ├── SoloShotTests/
│       └── SoloShotUITests/
├── services/
│   └── api/
│       ├── app/
│       │   ├── main.py
│       │   ├── api/
│       │   ├── domain/
│       │   ├── agent/
│       │   ├── skills/
│       │   ├── providers/
│       │   ├── media/
│       │   ├── persistence/
│       │   ├── analytics/
│       │   └── observability/
│       ├── tests/
│       │   ├── unit/
│       │   ├── integration/
│       │   ├── contract/
│       │   └── evals/
│       └── pyproject.toml
├── packages/
│   ├── contracts/
│   │   ├── openapi.yaml
│   │   ├── schemas/
│   │   └── fixtures/
│   ├── prompts/
│   │   ├── reference_understanding/
│   │   ├── scene_adaptation/
│   │   ├── result_evaluation/
│   │   └── content_composer/
│   └── design-tokens/
├── infra/
│   ├── docker-compose.yml
│   ├── migrations/
│   └── deployment/
├── scripts/
│   ├── generate-clients.sh
│   ├── seed-demo-data.py
│   ├── run-evals.py
│   └── render-demo-assets.py
└── docs/
    ├── adr/
    ├── api/
    ├── evals/
    ├── runbooks/
    └── demo/
```

如果现有仓库结构已经建立，不要为了完全匹配本结构进行大规模迁移；优先保持边界和依赖方向。

---

## 3. 技术栈与版本原则

### H5

- React、TypeScript、Vite；
- TanStack Query；
- Zustand 或现有轻量状态管理；
- Canvas/SVG 完成圈选和静态目标轮廓；
- MediaDevices/MediaRecorder 作为增强，文件上传必须是可靠后备；
- Playwright 做关键浏览器流程；
- Vitest + React Testing Library 做组件和状态测试。

### iOS

- Swift 6、SwiftUI；
- `AVCaptureSession`、`AVCaptureVideoDataOutput`、视频录制输出；
- Vision 人体姿态；
- `AVSpeechSynthesizer`；
- UIKit Feedback/Core Haptics；
- CALayer/SwiftUI Canvas；
- URLSession、Swift Concurrency、Codable；
- XCTest/XCUITest。

### 后端

- Python 3.12、FastAPI、Pydantic v2；
- PostgreSQL、Redis、对象存储；
- FFmpeg；
- pytest、mypy/pyright、ruff；
- OpenTelemetry 或结构化日志；
- provider adapters 隔离具体多模态模型。

### 依赖原则

- 锁定依赖版本；
- 禁止客户端直接调用模型 API；
- 领域层不得依赖具体模型 SDK、数据库或 Web 框架；
- 生成代码放在 `generated/`，禁止手改；
- 任何 provider 替换不应改变 Skill 对外 Schema。

---

## 4. 系统边界与数据流

```text
H5 / iOS
   │ HTTPS + Session ID
   ▼
API Gateway / Session API
   │
   ├── Agent Orchestrator
   │      ├── Reference Understanding
   │      ├── Shooting Plan
   │      ├── Scene Adaptation
   │      ├── Result Evaluation
   │      └── Content Composer
   │
   ├── Media Service (upload, thumbnails, FFmpeg, render)
   ├── Handoff Service
   ├── Persistence / Cache
   └── Analytics / Trace / Cost
```

### 核心调用约束

- H5/iOS 只调用后端业务 API，不直接选择 provider；
- Agent 负责选择 Skill，但实时 iOS Alignment 由本地状态机处理；
- iOS 可以把最终候选帧上传给 Result Evaluation；
- 后端返回固定问题标签和可控指令，不返回未经规则层校验的实时指导；
- Content Composer 生成真实文件或明确状态，不返回伪造发布成功。

---

## 5. 统一领域模型

所有坐标使用 0–1 归一化值。所有 DTO 必须版本化并包含 `schema_version`。

### 5.1 SoloShotSession

```json
{
  "schema_version": "1.0",
  "session_id": "ss_001",
  "state": "shot_plan_ready",
  "source_channel": "h5_qr",
  "mode": "scene_adaptation",
  "reference_asset": {},
  "user_constraints": {},
  "selected_skills": [],
  "shot_plan": {},
  "target_layout": {},
  "action_script": [],
  "capture_rounds": [],
  "evaluation": null,
  "publish_package": null,
  "analytics_context": {},
  "created_at": "2026-07-16T14:00:00+09:00",
  "updated_at": "2026-07-16T14:00:00+09:00"
}
```

### 5.2 TargetLayout

```json
{
  "center_x": 0.72,
  "center_y": 0.54,
  "width": 0.24,
  "height": 0.68,
  "head_point": {"x": 0.72, "y": 0.20},
  "foot_line_y": 0.88,
  "body_direction": "slightly_left",
  "pose_template": "walking_turn"
}
```

### 5.3 ShotPlan

至少包含：

- `camera_height`；
- `camera_angle`；
- `lens`；
- `capture_mode`；
- `phone_setup_instruction`；
- `target_layout`；
- `action_script`；
- `safety_notes`；
- `h5_execution`；
- `ios_execution`；
- `confidence`。

### 5.4 CurrentAlignment

```json
{
  "person_detected": true,
  "multiple_people": false,
  "full_body_visible": true,
  "position_status": "move_right",
  "scale_status": "move_back",
  "pose_status": "acceptable",
  "instruction_code": "move_right",
  "ready_to_capture": false,
  "stability_score": 0.71
}
```

### 5.5 ResultEvaluation

```json
{
  "issue_code": "person_too_large",
  "top_issue": "人物距离镜头过近，遮挡了背景主体",
  "next_instruction": "后退两步，其他动作保持不变",
  "needs_retake": true,
  "goal_satisfied": false,
  "publish_readiness": 0.62,
  "confidence": 0.81
}
```

### 5.6 AgentRun

记录：

- intent；
- selected skill versions；
- provider/model；
- status；
- latency；
- token/media cost；
- confidence；
- fallback；
- error code；
- trace spans。

### 5.7 HandoffTask

六位码或二维码只承载短 token，不嵌入敏感数据。任务必须可过期、撤销、认领并防重复认领。

---

## 6. Agent 和 Skill 运行规范

### 6.1 Agent Intent

最少支持：

```text
original_replication
scene_adaptation
result_evaluation
continue_coaching
content_generation
creator_template_generation
```

意图可由明确 UI 操作直接指定；不要为“Agent 感”强迫每次都让模型分类。只有自然语言或多义输入才使用模型意图识别。

### 6.2 Skill 接口

每个 Skill 实现统一协议：

```python
class Skill(Protocol[InputT, OutputT]):
    name: str
    version: str

    async def invoke(
        self,
        input: InputT,
        context: SkillContext,
    ) -> SkillResult[OutputT]: ...
```

`SkillResult` 必须包含：

- data；
- confidence；
- warnings；
- fallback_used；
- latency_ms；
- estimated_cost；
- provider metadata。

### 6.3 核心 Skills

**Reference Understanding**：视觉人物框、构图、机位、动作、背景和意图。  
**Shooting Plan**：把分析变成单人可执行任务。  
**Scene Adaptation**：保留镜头语言，基于现场图重算方案。  
**Result Evaluation**：比较参考、计划和成片，返回唯一最高优先级问题。  
**Content Composer**：生成结果卡、视频参数、文案和发布预览。  
**Growth Analytics**：聚合事件与成本，不承担关键交易写入。

`Coaching Decision` 的实时实现以 iOS 本地规则为主；后端可提供离线同构实现用于测试和 H5。

### 6.4 结构化输出处理

调用模型时：

1. 使用明确 JSON Schema；
2. 解析失败时只做有限次数修复；
3. 校验坐标范围、枚举和必填字段；
4. 低置信度进入用户圈选/澄清；
5. provider 错误进入缓存或规则 fallback；
6. 保存原始 provider response 的摘要或安全引用，用于调试，不在生产日志保存敏感媒体。

### 6.5 Prompt 版本

Prompt 存在 `packages/prompts/<skill>/<version>/`，至少包含：

- system prompt；
- schema；
- examples；
- changelog；
- eval cases。

代码不得内联长 Prompt。任何 Prompt 变更必须运行对应 eval。

---

## 7. API 契约

建议前缀 `/api/v1`。

### Session

```text
POST   /sessions
GET    /sessions/{session_id}
DELETE /sessions/{session_id}
```

### Reference

```text
POST /references/analyze
POST /references/adapt
POST /references/validate-box
GET  /references/{reference_id}
```

### Agent / Skills

```text
POST /agent/runs
POST /agent/runs/{run_id}/continue
GET  /agent/runs/{run_id}
GET  /agent/runs/{run_id}/trace
POST /skills/{skill_name}/invoke
```

### Capture / Evaluation

```text
POST /captures
POST /captures/{capture_id}/select-frame
POST /evaluations
GET  /captures/{capture_id}
```

### Handoff

```text
POST /handoffs
GET  /handoffs/{code}
POST /handoffs/{code}/claim
POST /handoffs/{code}/complete
DELETE /handoffs/{code}
```

### Content / Share

```text
POST /posts/render
GET  /posts/{post_id}
POST /posts/{post_id}/publish-preview
GET  /shares/{share_id}
```

### Analytics

```text
POST /events/batch
GET  /internal/metrics/funnel
GET  /internal/metrics/costs
```

内部指标接口必须鉴权；公开 H5 不应获得全局数据。

### API 行为要求

- 写操作支持 idempotency key；
- 长任务返回 job/run id，支持轮询或 SSE；
- 媒体使用签名 URL；
- 错误返回稳定的 `code`, `message`, `recoverable`, `retry_after`；
- 所有响应包含 `request_id`；
- 版本不兼容返回明确错误，不静默丢字段。

核心错误码：

```text
REFERENCE_NO_PERSON
REFERENCE_MULTIPLE_PEOPLE
REFERENCE_PARSE_FAILED
MODEL_TIMEOUT
INVALID_JSON
LOW_CONFIDENCE
CAPTURE_UPLOAD_FAILED
COMPARE_FAILED
VIDEO_RENDER_FAILED
HANDOFF_EXPIRED
HANDOFF_ALREADY_CLAIMED
SESSION_EXPIRED
UNSUPPORTED_MEDIA
```

---

## 8. H5 实现规格

### 8.1 必须完成的两条路径

**极速体验**

```text
预设视频 → 暂停/圈选 → 运行 Agent → ShotPlan → 真实样例评价 → 任务码/分享
```

**自定义体验**

```text
上传参考图/帧 → 圈选 → 用户限制 → Agent → ShotPlan → 上传成片 → Evaluation → Before/After
```

### 8.2 页面状态

建议 feature 级状态而非一个巨大页面状态机：

- reference source；
- crop/circle selection；
- user constraints；
- agent run；
- shot plan；
- capture/upload；
- evaluation；
- handoff；
- share。

刷新后应通过 session id 恢复关键状态。

### 8.3 圈选坐标

- 保存相对原媒体的归一化坐标；
- 正确处理 `object-fit: contain` 的 letterbox；
- 浏览器缩放、方向变化和高 DPR 下保持准确；
- 提供可拖拽、缩放和重置；
- 单元测试坐标转换函数。

### 8.4 相机/上传

- H5 相机是增强能力；
- 文件上传是可靠后备；
- 前端压缩图片时保留方向并限制最大边；
- 视频格式不兼容时给出可恢复提示；
- 大文件上传显示进度和取消；
- 不将整个视频 base64 塞入 JSON。

### 8.5 性能和兼容

目标：首屏可交互 ≤ 2.5 秒。测试 iOS Safari、Android Chrome、桌面 Chrome，并验证目标内置浏览器。预设资源应缓存，关键路由按需加载。

### 8.6 埋点

事件至少包括：

```text
page_view
reference_select
reference_upload
circle_complete
replicate_click
mode_select
agent_start
agent_success
agent_fail
shot_plan_view
h5_capture_start
result_upload
result_evaluated
handoff_qr_create
handoff_claimed
share_click
publish_preview
```

事件必须有 `session_id`, `source_channel`, `client`, `schema_version`, `timestamp`，并避免重复提交。

---

## 9. iOS 实现规格

### 9.1 AppFlowState

使用单一可测试状态机管理拍摄流程：

```swift
enum AppFlowState: Equatable {
    case launch
    case taskImport
    case referenceSummary
    case setup
    case cameraPreparing
    case aligning
    case ready
    case countdown
    case recording
    case processingFrames
    case selectingFrame
    case comparing
    case coaching
    case retake
    case finalResult
    case generatingPost
    case publishPreview
    case error(AppError)
}
```

任何异步任务必须有取消、失败和恢复路径。第二轮拍摄保留第一轮 capture 与建议。

### 9.2 CameraEngine

- Session 在专用串行队列；
- 固定后置主摄 1× 和竖屏；
- 输出 sample buffer 给 Vision；
- Vision 不处理每一帧；
- UI 更新回主线程；
- 支持视频录制和照片降级；
- 正确处理前后台、权限、来电/通知中断和资源释放。

### 9.3 VisionEngine

提取：头、肩、肘、腕、髋、膝、踝。输出纯领域类型，不让 Vision 类型泄漏到 UI。

多人选择规则：

1. 与目标轮廓交叠最大；
2. 完整度和置信度更高；
3. 仍有歧义时提示只保留一个人；
4. Debug/工作人员模式允许手动锁定。

Vision 失败时可降级为较粗边界、降低频率或手动“已就位”。

### 9.4 坐标映射

统一处理：

```text
Vision normalized coordinates
→ camera buffer orientation
→ preview layer aspect-fill crop
→ screen coordinates
```

坐标转换必须封装和单元测试。不要在 SwiftUI View 内散落翻转与缩放逻辑。

### 9.5 OverlayRenderer

显示目标轮廓、头部圆、脚底线、方向箭头、进度、倒计时和录制状态。生产 UI 不显示完整调试骨架；Debug 模式可切换显示。

### 9.6 AlignmentEngine

固定指令枚举：

```swift
enum AlignmentInstruction: String, Codable {
    case noPerson = "no_person"
    case multiplePeople = "multiple_people"
    case moveLeft = "move_left"
    case moveRight = "move_right"
    case moveForward = "move_forward"
    case moveBackward = "move_backward"
    case feetOutside = "feet_outside"
    case headOutside = "head_outside"
    case adjustBodyDirection = "adjust_body_direction"
    case adjustArm = "adjust_arm"
    case holdStill = "hold_still"
    case ready = "ready_to_capture"
}
```

优先级：

```text
无人 > 多人 > 不完整 > 大小 > 左右 > 姿势 > 稳定 > ready
```

初始阈值：横向 6%/12%，高度 10%/18%。最终从配置加载，不能硬编码散落。

防抖：

- 同结果连续 3 个采样才确认；
- 语音至少间隔 2 秒；
- 使用进入/退出迟滞；
- 冲突时短期保持前一条；
- ready 持续 1–1.5 秒才触发。

### 9.7 Speech/Haptics

文案来自本地映射表并可本地化。每次只播一句，4–12 个字，禁止自由模型文本。语音失败时仍显示文字和箭头；触觉是增强而非唯一提示。

### 9.8 CaptureEngine

- 默认 5–8 秒；
- ready → 说明动作 → 3 秒倒计时 → 录制 → 节奏提示 → 自动结束；
- 记录候选帧时间戳和元数据；
- 录制失败切换照片；
- 本地文件有生命周期管理。

### 9.9 FrameSelection

首版评分：完整、位置、比例、清晰度、简化姿势。用户必须可以手选；AI 推荐不强制。

### 9.10 离线行为

无网络仍可：导入已缓存任务、相机、Vision、Overlay、对齐、倒计时、录制和候选帧。评价和内容生成排队，网络恢复后继续。

---

## 10. 评价、纠偏和满足判断

固定问题标签：

```text
person_too_large
person_too_small
person_too_left
person_too_right
head_cut
feet_cut
background_blocked
pose_direction_wrong
arm_position_wrong
camera_too_high
camera_too_low
camera_angle_wrong
motion_timing_wrong
```

规则层将标签映射为唯一指令，例如：

- `person_too_large` → “后退两步，其他动作保持不变”；
- `person_too_left` → “向右移动一步，保持当前距离”；
- `feet_cut` → “手机稍微向下调整，确保脚部完整入镜”。

满足判断必须同时考虑：

- P0 构图问题是否在阈值内；
- 是否完整入镜；
- 置信度；
- 是否存在安全阻断；
- 用户是否选择接受结果。

不得用一个模糊总分替代可解释判断。

---

## 11. 媒体和内容生成

### 上传

- 客户端先请求签名 URL；
- 上传完成后提交 metadata；
- 校验 MIME、尺寸、时长和大小；
- 对象名不可使用用户原始文件名；
- 生成缩略图和标准化媒体。

### FFmpeg

封装命令，不在路由中拼接 shell。设置资源与超时上限。为演示准备确定性的渲染模板。

### 结果输出

至少真实生成：

- Before / After 图片；
- 9:16 视频：参考 1s → 第一张 1.5s → 建议 1s → 第二张 2s → CTA 1s。

“发布预览”只表示生成发布包，不表示已经发布到抖音。

---

## 12. 持久化建议

最小表：

- sessions；
- reference_assets；
- shot_plans；
- agent_runs；
- skill_runs；
- captures；
- evaluations；
- handoffs；
- posts；
- analytics_events；
- creator_templates。

使用迁移工具，禁止应用启动时自动修改生产表结构。Redis 用于短期 session cache、任务锁、幂等和作业状态，不作为唯一事实来源。

媒体保留策略应可配置。开发环境可以短周期自动删除，演示白名单可保留样例。

---

## 13. 隐私、安全与合规

- 本地实时检测不做人脸身份识别；
- 不建立人脸档案；
- 上传和发布前明确确认；
- 支持删除 session 与媒体；
- 日志不写 access token、原图字节和签名 URL；
- 参考内容只做镜头分析，不实现去水印搬运；
- 输出保留来源概念；
- 对危险站位进行阻断；
- 不评价身材、外貌或“颜值”；
- 任何公开分享 token 都需不可猜测且可过期。

---

## 14. 可观测性和评委面板

每个请求有 request id，每个 Agent run 有 trace id。结构化记录：

- intent；
- selected skills 与版本；
- provider/model；
- 延迟；
- token/媒体成本；
- JSON 修复次数；
- fallback；
- goal_satisfied；
- error code。

评委面板只显示安全摘要，不暴露 Prompt、密钥或用户敏感媒体。支持查看一条完整任务的时间线。

---

## 15. 测试策略

### 后端

- unit：领域规则、指令优先级、成本计算、Schema；
- contract：OpenAPI fixtures 和生成客户端兼容；
- integration：数据库、对象存储、Redis、FFmpeg、provider mock；
- evals：每个 Skill 的代表性素材集；
- end-to-end：参考 → 计划 → 上传 → 评价 → 内容。

### H5

- unit：坐标映射、状态恢复、埋点去重；
- component：圈选、错误恢复、任务码；
- Playwright：极速体验、自定义上传、Handoff、结果页；
- 浏览器矩阵：iOS Safari、Android Chrome、desktop Chrome。

### iOS

- unit：坐标映射、Alignment 优先级、迟滞、状态机；
- integration：缓存任务、网络恢复、本地文件生命周期；
- UI：导入任务、权限、拍摄、第二轮、错误恢复；
- device：弱光、多人、发热、通知、前后台、断网。

### 跨端

```text
H5 创建 → iOS 认领 → iOS 第一轮 → 后端评价 → 第二轮 → H5 查看 → 生成内容
```

### 关键质量阈值

- JSON 合法率 ≥ 98%；
- Skill 路径正确率 ≥ 95%；
- iOS 反馈 ≤ 500ms；
- 对齐 ≤ 20s；
- 接力 ≤ 5s；
- 评价 ≤ 8s；
- 双端主流程 ≥ 95%；
- 第二轮可见改善 ≥ 80%。

---

## 16. 工作包与依赖

Codex 不要一次性实现全部工作包。每个工作包完成后必须运行测试、更新文档并报告剩余风险。

### W0｜仓库、契约与本地环境

**交付**

- Monorepo 基础；
- `openapi.yaml` 和核心 schemas；
- `.env.example`；
- Docker Compose：Postgres、Redis、对象存储替代；
- 后端 `/health`；
- H5 skeleton；
- iOS skeleton；
- 生成 H5/iOS 类型的脚本；
- CI 骨架。

**验收**

- 一条命令启动后端依赖；
- 后端、H5 测试可运行；
- iOS scheme 可构建；
- fixture session 被两端解码。

### W1｜Agent/Skill API 最小闭环

**交付**

- Session API；
- Skill protocol、registry 和 orchestrator；
- Reference、Shooting Plan、Evaluation、Content 的 provider mock 与真实 adapter 接口；
- Agent run trace；
- 固定测试素材跑通。

**验收**

```text
reference fixture → ShotPlan → capture fixture → Evaluation → result card job
```

### W2｜H5 公开体验

**交付**

- 落地、预设素材、暂停圈选；
- 自定义上传；
- Agent 进度和结果；
- ShotPlan；
- 上传成片；
- Evaluation；
- Before/After；
- 关键埋点。

**验收**

- 无登录极速体验 ≤ 45 秒；
- 自定义图片真实请求；
- 刷新可恢复。

### W3｜跨端 Handoff

**交付**

- 创建、查询、认领、过期和撤销；
- H5 二维码/六位码；
- iOS 导入页面和缓存；
- 并发与幂等测试。

**验收**

- H5 创建后 iOS ≤ 5 秒导入同一 ShotPlan；
- 过期/重复认领行为明确。

### W4｜iOS 相机、Vision 和 Overlay

**交付**

- CameraEngine；
- VisionEngine；
- 坐标转换；
- OverlayRenderer；
- AlignmentEngine；
- 语音/触觉；
- Debug overlay。

**验收**

- 指定 iPhone 竖屏后置 1×；
- 无人/多人/单人行为正确；
- 反馈 ≤ 500ms；
- 单元测试覆盖坐标和迟滞。

### W5｜录制、候选、评价和第二轮

**交付**

- CaptureEngine；
- 本地候选帧；
- 上传；
- Result Evaluation；
- 唯一建议；
- 第二轮状态；
- 离线队列。

**验收**

- 完整第一轮和第二轮；
- 断网下仍能拍摄；
- 网络恢复后补评价。

### W6｜内容、创作者和增长

**交付**

- Before/After 文件；
- 9:16 视频；
- 发布预览；
- Creator Template 基础；
- 分享页；
- 漏斗、成本、Agent trace 面板。

**验收**

- 生成可下载媒体；
- 不虚构发布成功；
- 一条 session 的事件和成本可追踪。

### W7｜泛化、性能、容灾和冻结

**交付**

- 场景数据集与 eval report；
- 预设缓存；
- 多级 fallback；
- 压力和设备测试；
- Demo mode；
- 运行手册。

**验收**

- 双端与接力达到目标成功率；
- 30 次连续主流程；
- 备用链路真实可用。

---

## 17. 建议命令接口

在根目录提供稳定命令，底层实现可调整：

```bash
make bootstrap          # 安装/检查依赖
make dev-infra          # 启动 Postgres/Redis/object storage
make dev-api            # 启动 FastAPI
make dev-h5             # 启动 H5
make generate           # 从 OpenAPI/Schema 生成客户端类型
make lint
make typecheck
make test
make test-api
make test-h5
make test-contracts
make evals
make e2e-h5
make seed-demo
```

iOS 在 macOS 上至少提供文档化命令：

```bash
xcodebuild -project apps/ios/SoloShot.xcodeproj \
  -scheme SoloShot \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

需要真机的测试必须单独列出，不应让通用 CI 永久失败。

---

## 18. 环境变量

`.env.example` 只含占位符和说明，至少包括：

```text
APP_ENV
PUBLIC_BASE_URL
DATABASE_URL
REDIS_URL
OBJECT_STORAGE_ENDPOINT
OBJECT_STORAGE_BUCKET
OBJECT_STORAGE_ACCESS_KEY
OBJECT_STORAGE_SECRET_KEY
MODEL_PROVIDER
MODEL_API_KEY
MODEL_NAME_VISION
MODEL_NAME_TEXT
MEDIA_SIGNING_SECRET
HANDOFF_SIGNING_SECRET
OTEL_EXPORTER_OTLP_ENDPOINT
SENTRY_DSN
MOCK_AI_ENABLED=false
DEMO_PRESET_ENABLED=true
```

H5 只暴露明确允许的 `VITE_*` 公共变量；密钥不得进入客户端 bundle。

---

## 19. Definition of Done

一个工作项只有在以下条件全部满足时才算完成：

- 行为符合产品验收；
- 没有引入跨层依赖或复制业务规则；
- 关键路径有自动化测试；
- lint/typecheck/test 通过；
- 错误和恢复路径可用；
- 埋点和日志已加入且不含敏感数据；
- API/Schema 变更已重新生成客户端并通过契约测试；
- 文档和 `.env.example` 已同步；
- Mock/feature flag 状态清楚；
- Codex 输出变更摘要、验证命令、已知风险和下一步。

---

## 20. 明确非目标

首版不要实施：

- 与 H5 等价的 iOS 全页面；
- 与 iOS 等价的 H5 高频关键点追踪；
- 复杂三维人物和世界锚定；
- 未获许可的抖音客户端复刻或正式发布声称；
- 人脸身份识别或外貌评分；
- 通用旅游规划、预订和电商；
- 多人合照；
- 为了显示 Agent 而无条件调用所有 Skills；
- 用模型替代可由确定性规则完成的实时控制。

---

## 21. Codex 每次任务的输出格式

完成一次工作后，回复或提交说明应包含：

```text
Summary
- 实现了什么

Files changed
- 关键文件和原因

Validation
- 运行过的命令及结果

Behavior / screenshots
- 用户可见变化或录屏路径

Risks / assumptions
- 仍存在的风险、设备依赖、Mock 或未验证部分

Next recommended task
- 下一项最小可验证工作
```

遇到不明确细节时，先检查 `PRODUCT_OWNER_GUIDE.md`、契约和现有代码。只有会显著改变产品、数据模型、隐私或外部依赖的决策才询问用户；局部实现细节应自行选择最简单、可测试和可回退的方案。
