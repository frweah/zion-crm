"use client";

import { useActionState, useState } from "react";
import { money } from "@/lib/constants";
import { dismissWarrantLine, resolveWarrantLine, type WarrantState } from "./actions";

const initial: WarrantState = { error: null, ok: null };

export type AuthOption = { id: string; label: string; number: string };

/**
 * One stub line, however many scans read it (0376).
 *
 * `warrant_review_queue` answers one row per line on the warrant rather than
 * one per reading, so this is the stub's line and not a page's row: `line_id`
 * is the clearest reading, which is the one a decision is recorded against,
 * and `readings` says how many copies of the stub said the same thing.
 */
export type QueueLine = {
  key: string;
  line_id: string;
  line_no: number;
  raw: string;
  client_name: string;
  voucher: string;
  service_date: string | null;
  readings: number;
  scans: string[];
  ref: string;
  claim: string | null;
  auth_id: string | null;
  auth_number: string | null;
  amount: number | null;
  read_as: number[];
  why: string;
  page_why: string;
};

function Message({ state }: { state: WarrantState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

/**
 * One line the record cannot account for.
 *
 * The line as OCR read it, the one thing that is unknown about it, and the two
 * things a person can do after looking at the stub: say which authorization it
 * pays, or set it aside. The authorization list starts with the one the
 * database matched the V-number to, and then the ones whose number is close,
 * because a misread digit is the usual reason.
 */
export function WarrantLineReview({ line, auths }: { line: QueueLine; auths: AuthOption[] }) {
  const [state, action, recording] = useActionState(resolveWarrantLine, initial);
  const [dismissState, dismissAction] = useActionState(dismissWarrantLine, initial);
  const [dismissing, setDismissing] = useState(false);

  const read = line.ref.replace(/[^A-Z0-9]/gi, "").toUpperCase();
  const close = (n: string) => {
    const k = n.replace(/[^A-Z0-9]/gi, "").toUpperCase();
    return k === read || (read.length >= 6 && k.startsWith(read.slice(0, -1)));
  };
  const ordered = [...auths].sort(
    (a, b) =>
      Number(b.id === line.auth_id) - Number(a.id === line.auth_id) ||
      Number(close(b.number)) - Number(close(a.number)),
  );
  const suggested = ordered.find((a) => a.id === line.auth_id) ?? ordered.find((a) => close(a.number));

  return (
    <div style={{ padding: "10px 0", borderTop: "1px solid var(--line)" }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
        <span>
          <b>{line.ref || "no V-number"}</b>{" "}
          <span className="lock">
            {line.client_name || "?"}
            {line.claim ? ` · claim ${line.claim}` : ""}
            {line.service_date ? ` · DOS ${line.service_date}` : ""} ·{" "}
            {line.amount !== null ? money(line.amount) : line.read_as.map((a) => money(a)).join(" or ")}
            {line.voucher ? ` · voucher ${line.voucher}` : ""}
          </span>
        </span>
        <span className="chip warn">{line.why}</span>
      </div>
      <p className="lock" style={{ margin: "4px 0 6px", fontFamily: "ui-monospace, monospace", fontSize: "var(--text-sm)" }}>
        {line.raw}
      </p>
      {/*
        Which copies read it, and what the reader stopped on - the page's own
        reason, which is no longer why the line is here. A page whose total does
        not add up is asked about on "Does not add up".
      */}
      <p className="lock" style={{ margin: "0 0 6px" }}>
        {line.readings > 1 ? `Read on ${line.readings} scans: ${line.scans.join(", ")}. ` : ""}
        {line.page_why ? `The reader stopped on: ${line.page_why}` : ""}
      </p>

      <Message state={state} />
      <Message state={dismissState} />

      <form action={action} className="row2" style={{ gap: 8, alignItems: "flex-end" }}>
        <input type="hidden" name="line_id" value={line.line_id} />
        <label className="field" style={{ minWidth: 280, flex: 2 }}>
          Pays authorization
          <select name="auth_id" defaultValue={suggested?.id ?? ""}>
            <option value="">Choose, from the page image…</option>
            {ordered.map((a) => (
              <option key={a.id} value={a.id}>
                {a.id === line.auth_id || close(a.number) ? "≈ " : ""}
                {a.label}
              </option>
            ))}
          </select>
        </label>
        <label className="field" style={{ maxWidth: 140 }}>
          Amount
          {/*
            Blank where the scans disagree. Filling one of two readings in is
            how a figure nobody checked becomes the figure on the books.
          */}
          <input name="amount" inputMode="decimal" defaultValue={line.amount ?? ""} />
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
          <input type="hidden" name="line_id" value={line.line_id} />
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
