"use client";

import { useState, useActionState } from "react";
import Link from "next/link";
import {
  logSession,
  correctSession,
  submitStatement,
  decideStatement,
  reopenStatement,
  type HoursState,
} from "./actions";
import { today, fmtStamp } from "@/lib/constants";

const initial: HoursState = { error: null, ok: null };

type Option = { id: string; name: string };

export type SessionRow = {
  id: string;
  worked_on: string;
  hours: number;
  description: string;
  client_id: string | null;
  client_name: string;
  voided: boolean;
  corrects_id: string | null;
  correction_reason: string;
  statement_id: string | null;
  created_at: string;
  created_by_name: string;
};

function Message({ state }: { state: HoursState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export function LogSessionForm({ clients }: { clients: Option[] }) {
  const [state, action, pending] = useActionState(logSession, initial);

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <h3>Log work</h3>
      <Message state={state} />
      <form action={action}>
        <div className="row2">
          <label className="field" style={{ maxWidth: 170 }}>
            Day
            <input name="worked_on" type="date" max={today()} defaultValue={today()} required />
          </label>
          <label className="field" style={{ maxWidth: 110 }}>
            Hours
            <input name="hours" type="number" step="0.25" min="0.25" max="24" required />
          </label>
          <label className="field">
            Client (optional)
            <select name="client_id" defaultValue="">
              <option value="">— none —</option>
              {clients.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field" style={{ flex: 3 }}>
            What the time was spent on
            <input name="description" required placeholder="Job search with three clients, employer visits" />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Log"}
          </button>
        </div>
        <p className="lock" style={{ margin: "10px 0 0" }}>
          This is your billing record. Once logged an entry cannot be edited — a mistake is fixed
          by correcting it, which keeps both versions and your reason.
        </p>
      </form>
    </div>
  );
}

function CorrectForm({ session }: { session: SessionRow }) {
  const [state, action, pending] = useActionState(correctSession, initial);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button className="btn ghost" onClick={() => setOpen(true)} style={{ padding: "2px 10px" }}>
        Correct
      </button>
    );
  }

  return (
    <form action={action} style={{ minWidth: 280 }}>
      <input type="hidden" name="corrects_id" value={session.id} />
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
      <div className="row2" style={{ gap: 6 }}>
        <label className="field" style={{ maxWidth: 90, marginBottom: 0 }}>
          Hours
          <input name="hours" type="number" step="0.25" defaultValue={session.hours} required />
        </label>
        <label className="field" style={{ marginBottom: 0, flex: 2 }}>
          Description
          <input name="description" defaultValue={session.description} />
        </label>
      </div>
      <label className="field" style={{ marginTop: 6, marginBottom: 0 }}>
        Why
        <input name="correction_reason" required placeholder="Logged 6 by mistake; it was 4.5" />
      </label>
      <div className="row2" style={{ marginTop: 8, gap: 6 }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save correction"}
        </button>
        <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
    </form>
  );
}

export function SessionList({
  sessions,
  locked,
}: {
  sessions: SessionRow[];
  locked: boolean;
}) {
  const corrections = new Map(
    sessions.filter((s) => s.corrects_id).map((s) => [s.corrects_id!, s]),
  );

  if (sessions.length === 0) {
    return <div className="empty">Nothing logged for this period yet.</div>;
  }

  return (
    <div className="card" style={{ padding: 0 }}>
      <table className="t">
        <thead>
          <tr>
            <th>Day</th>
            <th>Hours</th>
            <th>Work</th>
            <th>Client</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {sessions
            .slice()
            .sort((a, b) => b.worked_on.localeCompare(a.worked_on))
            .map((s) => {
              const replacedBy = corrections.get(s.id);
              return (
                <tr key={s.id} style={s.voided ? { color: "var(--muted)" } : undefined}>
                  <td style={{ whiteSpace: "nowrap" }}>{s.worked_on}</td>
                  <td style={s.voided ? { textDecoration: "line-through" } : undefined}>
                    {s.hours}
                  </td>
                  <td>
                    {s.description}
                    {s.corrects_id && (
                      <div style={{ fontSize: 12, color: "var(--muted)" }}>
                        correction · {s.correction_reason}
                      </div>
                    )}
                    {s.voided && replacedBy && (
                      <div style={{ fontSize: 12, color: "var(--muted)" }}>
                        superseded — now {replacedBy.hours} hrs
                      </div>
                    )}
                  </td>
                  <td>
                    {s.client_id ? (
                      <Link href={`/clients/${s.client_id}`} style={{ color: "var(--teal)" }}>
                        {s.client_name}
                      </Link>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td style={{ textAlign: "right" }}>
                    {!s.voided && !locked && <CorrectForm session={s} />}
                    {locked && !s.voided && <span className="lock">settled</span>}
                  </td>
                </tr>
              );
            })}
        </tbody>
      </table>
    </div>
  );
}

export function SubmitStatement({
  periodStart,
  periodEnd,
  totalHours,
  totalAmount,
  unpricedHours,
  rateUnit,
  status,
  returnNote,
}: {
  periodStart: string;
  periodEnd: string;
  totalHours: number;
  totalAmount: number | null;
  unpricedHours: number;
  rateUnit: string | null;
  status: string | null;
  returnNote: string;
}) {
  const [state, action, pending] = useActionState(submitStatement, initial);

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h3 style={{ margin: 0 }}>
            {periodStart} to {periodEnd}
          </h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            {totalHours} hours logged
            {status && ` · statement ${status.toLowerCase()}`}
          </p>
          {totalAmount !== null && (
            <p className="sub" style={{ margin: "4px 0 0", fontWeight: 600 }}>
              Comes to{" "}
              {totalAmount.toLocaleString("en-US", { style: "currency", currency: "USD" })}
              {rateUnit === "Flat" && " — flat for the period"}
            </p>
          )}
          {unpricedHours > 0 && (
            <p className="lock" style={{ margin: "4px 0 0" }}>
              {unpricedHours} of those hours fall on days with no rate on file, so they are not in
              the figure above. Ask the administrator.
            </p>
          )}
          {totalAmount === null && (
            <p className="lock" style={{ margin: "4px 0 0" }}>
              No rate is on file yet, so this period has no figure. Your hours are still recorded.
            </p>
          )}
        </div>

        {status === "Approved" ? (
          <span className="chip ok">Approved — settled</span>
        ) : status === "Submitted" ? (
          <span className="chip warn">With Admin</span>
        ) : (
          <form action={action}>
            <input type="hidden" name="period_start" value={periodStart} />
            <input type="hidden" name="period_end" value={periodEnd} />
            <button className="btn gold" type="submit" disabled={pending || totalHours === 0}>
              {pending ? "Submitting…" : "Submit statement"}
            </button>
          </form>
        )}
      </div>

      <Message state={state} />

      {status === "Returned" && returnNote && (
        <div className="alert" style={{ marginTop: 10, marginBottom: 0 }}>
          <b>Returned:</b> {returnNote}
        </div>
      )}
    </div>
  );
}

export function ApprovalRow({
  statement,
}: {
  statement: {
    id: string;
    staff_name: string;
    period_start: string;
    period_end: string;
    status: string;
    total_hours: number;
    total_amount: number;
    unpriced_hours: number;
    rate_unit: string | null;
    adjustment: number;
    adjustment_note: string;
    submitted_at: string | null;
  };
}) {
  const [state, action, pending] = useActionState(decideStatement, initial);
  const [reopenState, reopenAction, reopening] = useActionState(reopenStatement, initial);
  const [returning, setReturning] = useState(false);

  return (
    <tr>
      <td>
        <b>{statement.staff_name}</b>
        <div style={{ fontSize: 12, color: "var(--muted)" }}>
          {statement.period_start} to {statement.period_end}
        </div>
        {(state.error ?? reopenState.error) && (
          <div style={{ color: "var(--bad)", fontSize: 12 }}>
            {state.error ?? reopenState.error}
          </div>
        )}
      </td>
      <td>
        {statement.total_hours} hrs
        {statement.unpriced_hours > 0 && (
          <div className="lock">{statement.unpriced_hours} on days with no rate</div>
        )}
      </td>
      <td>
        {statement.rate_unit === null && statement.total_amount === 0 ? (
          <span className="lock">no rate on file</span>
        ) : (
          <b>
            {statement.total_amount.toLocaleString("en-US", {
              style: "currency",
              currency: "USD",
            })}
          </b>
        )}
        {statement.rate_unit === "Flat" && <div className="lock">flat for the period</div>}
        {statement.adjustment !== 0 && (
          <div className="lock">
            includes {statement.adjustment > 0 ? "+" : ""}
            {statement.adjustment.toFixed(2)} — {statement.adjustment_note}
          </div>
        )}
      </td>
      <td>
        <span
          className={
            "chip " +
            (statement.status === "Approved" ? "ok" : statement.status === "Submitted" ? "warn" : "")
          }
        >
          {statement.status}
        </span>
        {statement.submitted_at && (
          <div style={{ fontSize: 11, color: "var(--muted)" }}>
            {fmtStamp(statement.submitted_at)}
          </div>
        )}
      </td>
      <td style={{ textAlign: "right" }}>
        {statement.status === "Submitted" && !returning && (
          <div className="row2" style={{ justifyContent: "flex-end", gap: 6 }}>
            <form action={action} style={{ display: "inline" }}>
              <input type="hidden" name="statement_id" value={statement.id} />
              <input type="hidden" name="decision" value="Approved" />
              <button className="btn gold" type="submit" disabled={pending}>
                {pending ? "…" : "Approve"}
              </button>
            </form>
            <button className="btn ghost" onClick={() => setReturning(true)}>
              Return…
            </button>
          </div>
        )}

        {statement.status === "Submitted" && returning && (
          <form action={action}>
            <input type="hidden" name="statement_id" value={statement.id} />
            <input type="hidden" name="decision" value="Returned" />
            <div className="row2" style={{ gap: 6, justifyContent: "flex-end" }}>
              <input name="return_note" placeholder="What needs changing" required style={{ maxWidth: 260 }} />
              <button className="btn" type="submit" disabled={pending}>
                Return
              </button>
              <button className="btn ghost" type="button" onClick={() => setReturning(false)}>
                Cancel
              </button>
            </div>
          </form>
        )}

        {statement.status === "Approved" && (
          <form action={reopenAction} style={{ display: "inline" }}>
            <input type="hidden" name="statement_id" value={statement.id} />
            <button className="btn ghost" type="submit" disabled={reopening}>
              {reopening ? "…" : "Reopen"}
            </button>
          </form>
        )}
      </td>
    </tr>
  );
}
