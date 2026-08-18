# SoloShot AI

> **从“刷到一个喜欢的镜头”，到“一个人真的把它拍出来”。**  
> 一个面向独自旅行场景的 AI 旅拍执行 Agent：理解参考画面、生成可执行 ShotPlan，并通过 H5 / iOS 在真实拍摄现场持续指导、评价和纠正。

<p align="left">
  <img alt="Python" src="https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white" />
  <img alt="FastAPI" src="https://img.shields.io/badge/FastAPI-0.116-009688?logo=fastapi&logoColor=white" />
  <img alt="React" src="https://img.shields.io/badge/React-19-61DAFB?logo=react&logoColor=black" />
  <img alt="TypeScript" src="https://img.shields.io/badge/TypeScript-5.9-3178C6?logo=typescript&logoColor=white" />
  <img alt="iOS" src="https://img.shields.io/badge/iOS-Native-000000?logo=apple&logoColor=white" />
  <img alt="MediaPipe" src="https://img.shields.io/badge/MediaPipe-On--device-4285F4" />
</p>

---

## 01｜为什么做这个项目

很多视觉 AI 产品停在“**看懂了**”：识别图片、解释画面、给出建议。

SoloShot AI 想把链路继续向现实世界推进一步：

```text
看到喜欢的旅拍内容
        ↓
理解镜头中的人物 / 构图 / 动作
        ↓
生成一个人也能执行的拍摄方案
        ↓
在真实现场实时判断“站对了吗 / 构图对了吗”
        ↓
拍摄 → 评价 → 给出一条最关键纠正 → 再拍一次
        ↓
得到可发布的 Before / After 内容
```

项目关注的不是“再生成一段摄影教程”，而是一个更具体的问题：

> **AI 能不能把互联网中的视觉灵感，转换成用户在真实世界里可以完成的行动？**

---

## 02｜核心产品闭环

SoloShot AI 采用 **「一核双端」** 架构：共享 Agent / Skills 负责理解与决策，H5 降低体验门槛，iOS 原生端负责最强的实时陪拍能力。

### ① Reference Understanding

用户输入参考照片 / 视频帧并圈选目标人物，系统提取拍摄任务需要的信息，而不是只做泛化图片描述。

关注的信息包括：

- 人物在画面中的位置与占比
- 全身 / 半身等景别
- 动作与身体朝向
- 机位与构图关系
- 背景结构与可迁移元素

### ② ShotPlan Agent

Agent 将视觉理解结果转换为真正可执行的拍摄任务：

- 人站在哪里
- 手机放在哪里
- 人物做什么动作
- 当前场景与参考图不一致时如何迁移灵感
- 本轮最需要关注的一个问题是什么

### ③ H5：低门槛体验

H5 用于完成“上传 → 分析 → ShotPlan → 拍摄 → 评价”的完整轻量路径，并支持浏览器端 MediaPipe Pose。

浏览器可以在本地完成：

- Pose 推理
- 人物位置 / 比例对齐
- 倒计时
- 多张候选照片排序
- 用户确认后仅上传最终选中 JPEG

即使没有安装 App，也可以跑通主要产品闭环。

### ④ iOS：实时执行层

iOS 原生端负责现场体验，通过 AVFoundation / Apple Vision 等能力完成：

- 原生相机预览
- 本地人体姿态识别
- 构图 Overlay
- 中文实时指令
- 语音 + 触觉反馈
- 短视频 / 多候选帧采集
- 弱网与离线任务恢复

这里刻意把“模型理解”和“实时视觉反馈”拆开：**大模型负责理解怎么拍，本地算法负责持续判断有没有拍对。**

### ⑤ Result Evaluation

拍摄后不是简单给一个分数，而是进入第二轮：

```text
第一次拍摄
   ↓
结果评价
   ↓
只给一条最高优先级纠正建议
   ↓
第二次拍摄
   ↓
Before / After 对比
```

这样可以把 AI 从“一次回答”变成一个真正具有反馈回路的执行 Agent。

---

## 03｜系统架构

```text
                         ┌─────────────────────────┐
                         │      SoloShot Agent     │
                         │  intent / skill routing │
                         └────────────┬────────────┘
                                      │
                ┌─────────────────────┼─────────────────────┐
                │                     │                     │
                ▼                     ▼                     ▼
       Reference Understanding     ShotPlan            Evaluation
           视觉理解 Skill          拍摄方案 Skill       结果评价 Skill
                │                     │                     │
                └───────────┬─────────┴───────────┬─────────┘
                            │                     │
                      Scene Adaptation      Coaching Decision
                            │                     │
                            └──────────┬──────────┘
                                       │
                     ┌─────────────────┴─────────────────┐
                     │                                   │
                     ▼                                   ▼
              React / H5                           Native iOS
        MediaPipe / Web Camera            Vision / AVFoundation
                     │                                   │
                     └─────────────────┬─────────────────┘
                                       ▼
                              FastAPI Service
                         task / media / handoff /
                         capture / evaluation APIs
                                       │
                       ┌───────────────┼───────────────┐
                       ▼               ▼               ▼
                  PostgreSQL         Redis           MinIO
```

---

## 04｜这个项目主要体现了什么能力

### AI 产品设计

不是把 LLM / VLM 做成一个聊天框，而是将 AI 拆成多个可组合的 **Skills**，嵌入完整用户任务：

- 理解视觉目标
- 生成行动方案
- 现场执行
- 结果评价
- 闭环纠正

### Agent / Workflow Engineering

核心链路围绕状态与任务推进，而不是一次 Prompt：

```text
Reference → Plan → Handoff → Capture → Evaluate → Retake → Result
```

H5 与 iOS 消费同一套任务语义，避免两个客户端各自维护一套业务逻辑。

### Full-stack Engineering

项目并非单页 Demo，而是一套完整 monorepo：

- **Frontend**：React 19 + TypeScript + Vite
- **Backend**：FastAPI + Pydantic + SQLAlchemy Async
- **Data / Infra**：PostgreSQL + Redis + MinIO
- **Native**：Swift / iOS / AVFoundation / Vision
- **Browser CV**：MediaPipe Tasks Vision
- **Contract**：OpenAPI + generated types
- **Testing**：Pytest / Vitest / Playwright / iOS tests

### Native × Web 协同

为了同时解决“访问门槛”和“实时能力”，项目没有强行只做一个端：

- H5：扫码即用、分享、快速体验
- iOS：相机、Vision、触觉、离线恢复等原生能力
- QR / Code Handoff：让同一个 ShotPlan 在设备之间继续执行

### Privacy-aware On-device AI

对实时视觉能力优先采用本地处理。浏览器 Pose、iOS Vision 坐标、实时相机预览等不需要持续上传到服务端；候选素材也在设备侧先筛选，再由用户确认最终上传内容。

### Engineering Reliability

仓库中不仅有产品代码，也覆盖：

- 类型检查与 lint
- API unit / integration tests
- H5 E2E
- handoff E2E
- iOS 测试
- 可恢复上传队列
- 离线任务缓存
- Fixture 与 Live 路径显式区分

这部分的目标是：**即使是 Hackathon 项目，也尽量按照可以继续迭代的产品工程方式构建，而不是只保证现场 Demo 能跑一次。**

---

## 05｜关键工程设计

### Contract-first

前后端与原生端优先围绕共享契约开发，生成代码统一放在 `generated/`，减少接口字段在多个客户端之间逐渐漂移。

### Secure H5 → iPhone Handoff

任务可以通过短时 QR / Code 从 H5 交给 iPhone：

- 有有效期
- 单设备原子领取
- capability 存入 Keychain
- App 本地保存任务摘要
- 弱网 / 离线时仍可恢复任务

### Resumable Capture Upload

拍摄结果通过有序 outbox 管理上传，而不是假设网络永远稳定；失败任务可以恢复，避免用户完成拍摄后因为一次网络中断丢失整个流程。

### Explicit Fixture / Live Boundary

为了保证 Demo 可重复，同时避免把固定样例伪装成真实模型能力：

- Fixture 路径明确标注
- 自定义媒体 / 场景迁移走 Live 模型路径
- Live 失败时不会静默降级成一个看起来“成功”的固定结果

---

## 06｜Repository Structure

```text
Hackathon/
├── apps/
│   ├── h5/                 # React / TypeScript H5
│   └── ios/                # Native iOS client
├── services/
│   └── api/                # FastAPI backend
├── contracts/              # shared API / schema contracts
├── docs/                   # runbooks & acceptance docs
├── reference/              # product / architecture design docs
├── scripts/                # development & validation scripts
├── AGENTS.md                # agent-oriented repository instructions
├── CODEX_IMPLEMENTATION_SPEC.md
├── PRODUCT_OWNER_GUIDE.md
└── Makefile
```

---

## 07｜Local Development

### Prerequisites

- Python 3.12
- Node.js 24+
- Java 21（OpenAPI Generator）
- Docker Desktop + Docker Compose
- macOS + Xcode 26 + XcodeGen 2.45+（iOS）

### Bootstrap

```bash
make bootstrap
make generate
```

### Run

```bash
cp .env.example .env
make dev-infra
make migrate
make dev-api
make dev-h5
```

本地服务：

- API Health: `http://127.0.0.1:8000/health`
- H5: `http://127.0.0.1:5173`
- MinIO Console: `http://127.0.0.1:9001`

---

## 08｜Validation

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

---

## 09｜Current Scope

当前仓库已经覆盖从参考画面理解、ShotPlan、H5、跨设备 handoff、iOS 实时陪拍，到拍摄评价与二次纠正的工程链路。

需要特别说明的是：

- Fixture 用于稳定测试与演示，并与 Live 模型结果显式区分；
- H5 MediaPipe 路径能够在浏览器完成本地 Pose 推理，但不宣称与 iOS 的短视频、触觉、设备压力处理能力完全一致；
- 真机相机、Vision、热状态、中断恢复、弱网等能力仍需要在目标 iPhone 环境持续做设备级验收；
- Live 模型质量与真实设备工程验收是两个不同问题，仓库中分别处理。

---

## 10｜一句话总结

**SoloShot AI 的核心并不是“AI 帮你分析一张照片”，而是尝试完成从视觉理解 → Agent 决策 → 真实世界执行 → 结果反馈的完整闭环。**

这也是这个项目最想验证的方向：

> **让 AI 不只回答用户，而是帮助用户把一件现实中的事情真正做完。**
