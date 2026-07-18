# ADR 0002：W1 Agent/Skill 运行时与持久化

- 状态：已接受
- 日期：2026-07-17

## 背景

W1 需要在不依赖 H5 或 iOS 的情况下证明“参考理解→拍摄方案→成片评价→内容任务”闭环，同时不能把固定结果伪装成实时模型输出。

## 决策

- 公共 DTO 继续以 `packages/contracts/` 为唯一事实来源，并生成 H5、Swift 和 Python 类型。
- Agent 通过版本化 Skill registry 选择能力；同一个 run 的 Skill trace 使用有序数组保存。
- W1 本地默认使用确定性 Mock Provider，成本为零，并通过响应头、trace、warning 和文档明确标记。
- 真实模型只定义 `StructuredModelProvider` 端口，不引入厂商 SDK 或凭据。
- PostgreSQL 是 Session 和运行轨迹的事实来源；Redis 不作为 W1 唯一存储。
- Alembic 负责迁移，应用启动时不自动修改表结构。
- W1 内容能力只创建 `queued` job，不返回不存在的媒体文件或发布成功状态。

## 影响

W2 可以直接恢复 Session 和 ShotPlan；未来 Provider adapter 不改变 Skill 输出 Schema。真实媒体处理、Handoff 和 Scene Adaptation 仍需各自工作包完成。
