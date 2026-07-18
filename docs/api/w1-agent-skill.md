# W1 Agent/Skill API

## 可运行闭环

```text
POST /api/v1/sessions
→ POST /api/v1/references/analyze
→ POST /api/v1/agent/runs
→ POST /api/v1/captures
→ POST /api/v1/agent/runs/{run_id}/continue
→ GET /api/v1/agent/runs/{run_id}/trace
→ GET /api/v1/sessions/{session_id}
```

首次 Agent 调用依次运行 `reference_understanding@1.0.0` 和 `shooting_plan@1.0.0`。继续调用依次追加 `result_evaluation@1.0.0` 和 `content_composer@1.0.0`。

## 幂等和错误

所有写接口使用 PostgreSQL 事务保存业务资源和幂等记录；同一幂等键、同一请求体会重放同一资源并在 AI 响应中返回 `X-SoloShot-Execution-Mode: cache`，同一键配合不同请求体返回 `IDEMPOTENCY_CONFLICT`。Session 删除会级联清理其 W1 数据和关联幂等记录。

所有写操作必须提供 8–128 字符的 `Idempotency-Key`。相同 key 和相同请求返回同一资源；相同 key 搭配不同请求返回 `409 IDEMPOTENCY_CONFLICT`。错误响应包含稳定的 `code`、`message`、`recoverable`、`retry_after` 和与 `X-Request-ID` 一致的 `request_id`。

## Mock 与真实性

本地 W1 不调用真实模型。AI 相关响应带 `X-SoloShot-Execution-Mode: mock`，Skill trace 的 provider 为 `mock`、成本为 `0`，warning 明确说明结果不是实时模型输出。Content Composer 只返回 `queued` job，`output_asset_id` 必须为 `null`。

## 当前边界

W1 只验收 `original_replication`。Scene Adaptation、Creator Template、Growth Analytics、Handoff、真实渲染和发布预览返回明确不可用行为或由后续工作包实现。
