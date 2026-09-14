"use client";

import { useActionState, useState } from "react";
import { money } from "@/lib/constants";
import { dismissWarrantLine, resolveWarrantLine, type WarrantState } from "./actions";

const initial: WarrantState = { error: null, ok: null };

export type AuthOption = { id: string; label: string; number: string };

export type ReviewLine = {
  id: string;
  line_no: number;
  raw: string;
  voucher: string;
  invoice_ref: string;
  described_ref: string;
  client_name: string;
  service_date: string | null;
  amount: number | null;
  described_amount: number | null;
  status: string;
  problem: string;
};

function Message({ state }: { state: WarrantState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

/**
 * One line that could not be proved from the page.
 *
 * The line as OCR read it, why it stopped, and the two things a person can do
 * after looking at the stub: say which authorization it pays, or set it aside.
 * The authorization list starts with the ones whose number matches either
 * V-number read on the line, because a misread digit is the usual reason.
 */
export function WarrantLineReview({ line, auths }: { line: ReviewLine; auths: AuthOption[] }) {
  const [state, action, recording] = useActionState(resolveWarrantLine, initial);
  const [dismissState, dismissAction] = useActionState(dismissWarrantLine, initial);
  const [dismissing, setDismissing] = useState(false);

  const read = [line.invoice_ref, line.described_ref].map((r) => r.replace(/[^A-Z0-9]/gi, "").toUpperCase()).filter(Boolean);
  const close = (n: string) => {
    const k = n.replace(/[^A-Z0-9]/gi, "").toUpperCase();
    return read.some((r) => r === k || (r.length >= 6 && k.startsWith(r.slice(0, -1))));
  };
  const ordered = [...auths].sort((a, b) => Number(close(b.number)) - Number(close(a.number)));
  const suggested = ordered.find((a) => close(a.number));

  return (
    <div style={{ padding: "10px 0", borderTop: "1px solid var(--line)" }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
        <span>
          <b>Line {line.line_no}</b>{" "}
          <span className="lock">
            {line.invoice_ref || "no V-number"} / {line.client_name || "?"} · {line.described_ref || "?"}
            {line.service_date ? ` · DOS ${line.service_date}` : ""} · {line.amount !== null ? money(line.amount) : "no amount"}
            {line.voucher ? ` · voucher ${line.voucher}` : ""}
          </span>
        </span>
        <span className="chip warn">{line.problem || "Needs review"}</span>
      </div>
      <p className="lock" style={{ margin: "4px 0 6px", fontFamily: "ui-monospace, monospace", fontSize: 12 }}>
        {line.raw}
      </p>

      <Message state={state} />
      <Message state={dismissState} />

      <form action={action} className="row2" style={{ gap: 8, alignItems: "flex-end" }}>
        <input type="hidden" name="line_id" value={line.id} />
        <label className="field" style={{ minWidth: 280, flex: 2 }}>
          Pays authorization
          <select name="auth_id" defaultValue={suggested?.id ?? ""}>
            <option value="">Choose, from the page image…</option>
            {ordered.map((a) => (
              <option key={a.id} value={a.id}>
                {close(a.number) ? "≈ " : ""}
                {a.label}
              </option>
            ))}
          </select>
        </label>
        <label className="field" style={{ maxWidth: 140 }}>
          Amount
          <input name="amount" inputMode="decimal" defaultValue={line.amount ?? line.described_amount ?? ""} />
        </label>
        <button className="btn gold" type="submit" disabled={recording}>
          {recording ? "…" : "Record payment"}
        </button>
        {!dismissing && (
          <button className="btn ghost" type="button" onClick={() => setDismissing(true)}>
            Set aside
          </button>
        )}
      </form>

      {dismissing && (
        <form action={dismissAction} className="row2" style={{ gap: 6, marginTop: 6 }}>
          <input type="hidden" name="line_id" value={line.id} />
          <input name="reason" placeholder="Why — a duplicate, another vendor's line, a misread…" required />
          <button className="btn" type="submit">
            Set aside
          </button>
          <button className="btn ghost" type="button" onClick={() => setDismissing(false)}>
            Cancel
          </button>
        </form>
      )}
    </div>
  );
}
