# Test Image v1 H5 Design QA

## 对比基准

- source visual truth path：`docs/ChatGPT Image Jul 17, 2026 at 01_57_33 PM.png`
- implementation screenshot path：
  - `artifacts/design-qa/gallery-390x844.png`
  - `artifacts/design-qa/constraints-390x844-final.png`
  - `artifacts/design-qa/shot-plan-390x844-final.png`
  - `artifacts/design-qa/evaluation-390x844-final.png`
  - `artifacts/design-qa/complete-390x844-final.png`
- viewport：390 × 844，deviceScaleFactor 1
- state：Test Image v1 演示模式，门廊全身案例，完整走通约束、ShotPlan、第一轮评价和第二轮改进。

## 全屏与局部对比证据

- `artifacts/design-qa/constraints-comparison-final.png`：对比总览图的约束/模式页与实际约束页。
- `artifacts/design-qa/shot-plan-comparison-final.png`：对比总览图的 ShotPlan 页与实际 ShotPlan 页。
- `artifacts/design-qa/evaluation-comparison-final.png`：对比总览图的成片评价页与实际评价页。
- 重点局部已覆盖顶部品牌栏、双图构图区、橙色主操作、绿色成功状态、评价问题卡和移动端底部操作位置，无需额外放大裁切。

## Findings

- 无剩余 P0、P1 或 P2 问题。
- P3：真实 Round 1 / Round 2 照片尚未提供，因此结果页使用状态卡而不是伪造成片；页面已明确说明 Fixture 边界，待实拍素材补齐后可替换。

## 必查表面

- 字体与排版：使用系统中文字体栈，标题、正文、说明层级与总览图一致；修正后最小业务说明字号为 9px，主要说明为 10–11px，无截断或异常换行。
- 间距与布局：390px 宽度下无水平滚动；四个关键页面的主操作固定在屏幕底部安全区域，内容区保持来源设计的紧凑密度。
- 颜色与视觉 Token：深海军蓝背景、品牌橙、成功绿和中性边框与视觉总览一致；Mock/Fixture 使用独立状态色且对比清晰。
- 图片质量：4 个公开预设均使用真实授权素材和 WebP 派生图，无远程资源、占位图或代码绘制图片；裁切保持主体可见。
- 文案：持续显示“演示模式”“Fixture 状态模拟”“不是实时模型判断”，未把确定性数据描述为实时 AI 输出。
- 图标：全部来自同一 Phosphor 图标族，无 emoji、自绘 SVG 或 CSS 图标替代。
- 交互与无障碍：主要按钮高度 50px、品牌返回按钮高度 44px；具备可见焦点、语义按钮、图片替代文本、非音频状态提示和减少动态效果支持。

## 对比历史

1. 首次对比发现 P2：约束、ShotPlan 和评价页的主按钮跟随内容，屏幕底部出现不一致的空白节奏。
2. 修正：将四个关键任务页改为纵向布局，并用自动间距把主操作锚定到底部；同时提高 ShotPlan 和约束说明字号。
3. 修正后证据：三个 `*-comparison-final.png` 显示主操作位置与来源设计一致；浏览器复查结果为 `scrollWidth=390`、`scrollHeight=844`，控制台无 error 或 warning。

## 交互检查

- 已测试：预设选择、约束选择、Agent loading、ShotPlan、第一轮唯一建议、第二轮达标、刷新恢复、API 错误与重试入口。
- 浏览器控制台：0 个 error，0 个 warning。
- Playwright：390 × 844 关键路径通过。

final result: passed
