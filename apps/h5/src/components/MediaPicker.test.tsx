// @vitest-environment jsdom

import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { UploadProgress } from "./MediaPicker";

afterEach(cleanup);

describe("UploadProgress", () => {
  it("exposes progress without audio and lets the user cancel", async () => {
    const user = userEvent.setup();
    const cancel = vi.fn();
    render(<UploadProgress value={42} onCancel={cancel} />);

    expect(screen.getByLabelText("上传进度 42%")).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "取消" }));
    expect(cancel).toHaveBeenCalledOnce();
  });
});
