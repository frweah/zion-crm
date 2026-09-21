"use client";

import { useEffect, useRef, useState } from "react";
import { freshInboxPdfUrl, noteViewerEvent } from "./pdf-actions";

/** Long enough for a 50 MB scan on office broadband; short enough to notice. */
const TIMEOUT_MS = 15000;

type Status = "checking" | "loading" | "ok" | "failed";

/**
 * The document-review PDF, with a way back when it does not show
 * (punch list #16).
 *
 * An iframe cannot say that what it loaded was an error page: a link that
 * has expired shows Supabase's error text inside the frame, and the frame
 * reports it as loaded. So the file is asked for first - its first bytes,
 * which should be "%PDF" - and only a file that answers as a PDF is put in
 * the frame. Anything else, or a frame that never finishes, says so and
 * offers a fresh link and the file in a tab of its own. Every outcome is
 * logged (pdf-actions.ts) so a glitch can be looked up afterwards.
 */
export function PdfFrame({ docId, initialUrl, title }: { docId: string; initialUrl: string | null; title: string }) {
  const [url, setUrl] = useState(initialUrl);
  const [status, setStatus] = useState<Status>(initialUrl ? "checking" : "failed");
  const [why, setWhy] = useState(initialUrl ? "" : "No link to the file could be made.");
  const [attempt, setAttempt] = useState(0);
  const started = useRef(0);
  const settled = useRef(false);

  // Ask for the first bytes before framing it.
  useEffect(() => {
    if (!url) return;
    let cancelled = false;
    settled.current = false;
    started.current = performance.now();
    setStatus("checking");
    (async () => {
      try {
        const res = await fetch(url, { headers: { Range: "bytes=0-4" }, cache: "no-store" });
        if (cancelled) return;
        if (!res.ok) {
          fail(`The file answered ${res.status}${res.status === 400 || res.status === 403 ? " - the link has probably expired" : ""}.`);
          return;
        }
        const head = new TextDecoder().decode(new Uint8Array(await res.arrayBuffer()).slice(0, 5));
        if (cancelled) return;
        if (!head.startsWith("%PDF")) {
          fail("What came back is not a PDF.");
          return;
        }
      } catch {
        // A network or cross-origin refusal of the check itself is not proof
        // the file is bad - let the frame try, and let the timeout judge it.
        if (cancelled) return;
      }
      setStatus("loading");
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [url, attempt]);

  // A frame that never finishes loading.
  useEffect(() => {
    if (status !== "loading") return;
    const t = setTimeout(() => {
      if (settled.current) return;
      settled.current = true;
      setStatus("failed");
      setWhy("The viewer did not finish loading.");
      void noteViewerEvent({ docId, event: "timeout", ms: performance.now() - started.current });
    }, TIMEOUT_MS);
    return () => clearTimeout(t);
  }, [status, docId]);

  function fail(reason: string) {
    if (settled.current) return;
    settled.current = true;
    setStatus("failed");
    setWhy(reason);
    void noteViewerEvent({ docId, event: "failed", ms: performance.now() - started.current, detail: reason });
  }

  function loaded() {
    if (settled.current) return;
    settled.current = true;
    setStatus("ok");
    void noteViewerEvent({ docId, event: "loaded", ms: performance.now() - started.current });
  }

  async function retry() {
    void noteViewerEvent({ docId, event: "retried" });
    setWhy("");
    setStatus("checking");
    const fresh = await freshInboxPdfUrl(docId);
    if (!fresh) {
      settled.current = false;
      fail("A fresh link could not be made. The document may have been filed or moved.");
      return;
    }
    setUrl(fresh);
    setAttempt((n) => n + 1);
  }

  return (
    <div style={{ position: "relative" }}>
      {status === "failed" ? (
        <div className="empty" style={{ padding: 20 }} role="alert">
          <p style={{ margin: "0 0 10px" }}>The PDF did not show. {why}</p>
          <div className="row2" style={{ gap: 8 }}>
            <button className="btn gold" type="button" onClick={() => void retry()}>
              Try again
            </button>
            {url && (
              <a className="btn ghost" href={url} target="_blank" rel="noopener noreferrer" style={{ textDecoration: "none" }}>
                Open in a new tab
              </a>
            )}
          </div>
          <p className="lock" style={{ margin: "10px 0 0" }}>Nothing on this page has been lost - what was read from it is beside this.</p>
        </div>
      ) : (
        <>
          {status !== "ok" && (
            <p className="lock" style={{ position: "absolute", top: 12, left: 16, margin: 0 }}>
              Opening the PDF…
            </p>
          )}
          {status !== "checking" && url && (
            <iframe
              key={`${attempt}`}
              src={url}
              title={title}
              onLoad={loaded}
              onError={() => fail("The viewer reported an error.")}
              style={{ width: "100%", height: 720, border: 0, display: "block" }}
            />
          )}
          {status === "ok" && url && (
            <a
              className="lock"
              href={url}
              target="_blank"
              rel="noopener noreferrer"
              style={{ display: "block", padding: "6px 12px" }}
            >
              Open in a new tab
            </a>
          )}
        </>
      )}
    </div>
  );
}
