import { useEffect, useState } from "react";
import { renderHandoffQrDataUrl } from "../handoff/qr";

export function HandoffQr({ payload }: { payload: string }) {
  const [source, setSource] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setSource(null);
    void renderHandoffQrDataUrl(payload).then((url) => {
      if (active) {
        setSource(url);
      }
    });
    return () => {
      active = false;
    };
  }, [payload]);

  return (
    <div className="handoff-qr" role="img" aria-label="iPhone 接力二维码">
      {source === null ? <span>正在生成二维码…</span> : <img src={source} alt="iPhone 接力二维码" />}
    </div>
  );
}
