"use client";

import { useActionState, useEffect } from "react";
import { downloadTaxForm, type PaperworkState } from "./actions";

const initial: PaperworkState & { url?: string } = { error: null, ok: null };

/**
 * Opens a filed form.
 *
 * The link is minted on demand and lasts two minutes: the bucket is private and
 * Admin-only, so there is no durable URL to hand around. Opening it in a new
 * tab as soon as it arrives keeps the short-lived link out of the page.
 */
export function DownloadButton({
  pdfPath,
  submissionId,
  label,
}: {
  pdfPath: string;
  submissionId: string;
  label?: string;
}) {
  const [state, action, pending] = useActionState(downloadTaxForm, initial);

  useEffect(() => {
    if (state.url) window.open(state.url, "_blank", "noopener");
  }, [state.url]);

  if (!pdfPath) return <span className="lock">no file</span>;

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="pdf_path" value={pdfPath} />
      {/* The submission, so the database can write down who opened which form. */}
      <input type="hidden" name="submission_id" value={submissionId} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "Opening…" : (label ?? "Open")}
      </button>
      {state.error && (
        <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>
      )}
    </form>
  );
}
