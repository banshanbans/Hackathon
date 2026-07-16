const foundations = [
  "共享 OpenAPI 与 JSON Schema",
  "FastAPI 健康检查",
  "H5 与 iOS 类型生成",
  "Postgres、Redis 与 MinIO 本地依赖",
] as const;

export function App() {
  return (
    <main className="shell">
      <section className="hero" aria-labelledby="page-title">
        <p className="eyebrow">SOLOSHOT AI · W0</p>
        <h1 id="page-title">把旅行灵感，变成一个人能完成的镜头。</h1>
        <p className="lede">
          当前页面是可运行的工程基础骨架。Agent、镜头分析与拍摄评价将在后续工作包接入；这里不展示伪造的实时 AI 结果。
        </p>
        <div className="status" role="status">
          <span className="status-dot" aria-hidden="true" />
          契约优先基础已就绪
        </div>
      </section>

      <section className="foundation" aria-labelledby="foundation-title">
        <p className="section-label">W0 FOUNDATION</p>
        <h2 id="foundation-title">同一份任务契约，服务 H5、iOS 与 API。</h2>
        <ul>
          {foundations.map((foundation) => (
            <li key={foundation}>{foundation}</li>
          ))}
        </ul>
      </section>
    </main>
  );
}

