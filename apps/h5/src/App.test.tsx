import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { App } from "./App";

describe("App", () => {
  it("labels the page as an honest W0 foundation", () => {
    const markup = renderToStaticMarkup(<App />);

    expect(markup).toContain("W0");
    expect(markup).toContain("不展示伪造的实时 AI 结果");
    expect(markup).toContain("同一份任务契约");
  });
});

