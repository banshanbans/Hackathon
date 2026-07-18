// @vitest-environment jsdom

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HandoffLandingScreen, HandoffScreen } from "./HandoffScreens";

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() {
      return values.size;
    },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => values.delete(key),
    setItem: (key, value) => values.set(key, value),
  };
}

function response(data: unknown, status = 200): Response {
  return new Response(JSON.stringify({ schema_version: "1.0", request_id: "req_w3", data }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const created = {
  schema_version: "1.0" as const,
  handoff: {
    schema_version: "1.0" as const,
    handoff_id: "handoff_test",
    code: "ABC234",
    status: "created" as const,
    mode: "original_replication" as const,
    created_at: "2099-01-01T00:00:00Z",
    expires_at: "2099-01-01T00:10:00Z",
    claimed_at: null,
    completed_at: null,
  },
  management_token: "management-secret-not-for-url",
  qr_payload: "https://handoff.example.test/handoff/ABC234",
};

function wrapper(path: string, element: React.ReactNode) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/session/:id/handoff" element={element} />
          <Route path="/handoff/:code" element={element} />
          <Route path="/session/:id/plan" element={<div>ShotPlan 已恢复</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("W3 handoff screens", () => {
  let sessionStorage: Storage;
  let localStorage: Storage;

  beforeEach(() => {
    sessionStorage = memoryStorage();
    localStorage = memoryStorage();
    Object.defineProperty(window, "sessionStorage", { configurable: true, value: sessionStorage });
    Object.defineProperty(window, "localStorage", { configurable: true, value: localStorage });
    vi.stubGlobal("sessionStorage", sessionStorage);
    vi.stubGlobal("localStorage", localStorage);
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("creates a real QR handoff and keeps the management token in sessionStorage only", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(String(input));
        if (url.pathname === "/api/v1/handoffs" && init?.method === "POST") {
          return response(created, 201);
        }
        if (url.pathname === "/api/v1/handoffs/ABC234") {
          return response(created.handoff);
        }
        if (url.pathname === "/api/v1/events/batch") {
          return response({ schema_version: "1.0", accepted_count: 1, duplicate_count: 0 }, 202);
        }
        throw new Error(`unexpected ${url.pathname}`);
      }),
    );

    wrapper("/session/ss_w3/handoff", <HandoffScreen />);

    expect(await screen.findByLabelText("任务码 ABC234")).toBeTruthy();
    expect(await screen.findByAltText("iPhone 接力二维码")).toBeTruthy();
    await waitFor(() => expect(sessionStorage.length).toBe(1));
    expect(sessionStorage.getItem("soloshot:handoff:v1:ss_w3")).toContain(
      "management-secret-not-for-url",
    );
    for (let index = 0; index < localStorage.length; index += 1) {
      expect(localStorage.getItem(localStorage.key(index) ?? "")).not.toContain(
        "management-secret-not-for-url",
      );
    }
    expect(window.location.href).not.toContain("management-secret-not-for-url");
  });

  it("renders only the safe public preview on the HTTPS landing route", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => response(created.handoff)));
    wrapper("/handoff/ABC234", <HandoffLandingScreen />);

    expect(await screen.findByRole("button", { name: "打开 SoloShot" })).toBeTruthy();
    expect(screen.getByText("原图复刻")).toBeTruthy();
    expect(document.body.textContent).not.toContain("ss_");
    expect(document.body.textContent).not.toContain("management-secret");
  });

  it("lets the browser owner revoke a claimed but incomplete handoff", async () => {
    const claimed = {
      ...created.handoff,
      status: "claimed" as const,
      claimed_at: "2099-01-01T00:01:00Z",
    };
    sessionStorage.setItem(
      "soloshot:handoff:v1:ss_w3",
      JSON.stringify({
        sessionId: "ss_w3",
        createIdempotencyKey: "h5-create-claimed-test",
        code: "ABC234",
        managementToken: created.management_token,
        qrPayload: created.qr_payload,
      }),
    );
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      if (url.pathname === "/api/v1/handoffs/ABC234" && init?.method === "DELETE") {
        return response({ ...claimed, status: "revoked" });
      }
      if (url.pathname === "/api/v1/handoffs/ABC234") {
        return response(claimed);
      }
      throw new Error(`unexpected ${url.pathname}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    wrapper("/session/ss_w3/handoff", <HandoffScreen />);
    fireEvent.click(await screen.findByRole("button", { name: "撤销接力并回到网页" }));

    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining("/api/v1/handoffs/ABC234"),
        expect.objectContaining({ method: "DELETE" }),
      ),
    );
    expect(await screen.findByText("ShotPlan 已恢复")).toBeTruthy();
  });
});
