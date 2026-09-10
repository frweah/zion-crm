"use client";

import { useActionState, useState } from "react";
import {
  savePolicy,
  confirmPolicy,
  placeHold,
  liftHold,
  recordDisposition,
  type RetentionState,
} from "./actions";

const initial: RetentionState = { error: null, ok: null };

export type Policy = {
  key: string;
  label: string;
  what: string;
  keep_years: number;
  clock_starts: string;
  authority: string;
  confirmed: boolean;
  confirmed_at: string | null;
};

export type Row = {
  client_id: string;
  name: string;
  closed_on: string | null;
  keep_until: string | null;
  policy_confirmed: boolean | null;
  on_hold: boolean | null;
  hold_id: string | null;
  hold_reason: string | null;
  due: boolean | null;
  disposed_at: string | null;
  disposed_action: string | null;
};

export type Hold = {
  id: string;
  client_id: string;
  reason: string;
  placed_by_name: string;
  placed_at: string;
};

export type Disposition = {
  id: number;
  client_name: string;
  action: string;
  reason: string;
  decided_by_name: string;
  disposed_at: string;
};

const date = (s: string | null) => (s ? new Date(s + "T12:00:00").toLocaleDateString() : "—");
const stamp = (s: string) => new Date(s).toLocaleDateString();

/** One period, and whether anybody has checked it. */
function PolicyCard({ policy }: { policy: Policy }) {
  const [saveState, save, saving] = useActionState(savePolicy, initial);
  const [confState, confirm, confirming] = useActionState(confirmPolicy, initial);
  const [open, setOpen] = useState(false);

  return (
    <div className="card" style={{ marginTop: 12 }}>
      <div className="row2" style={{ alignItems: "baseline" }}>
        <h3 style={{ margin: 0 }}>{policy.label}</h3>
        {policy.confirmed ? (
          <span className="chip">
            Confirmed{policy.confirmed_at ? ` ${stamp(policy.confirmed_at)}` : ""}
          </span>
        ) : (
          <span className="chip bad">Not checked by anybody</span>
        )}
      </div>
      <p className="sub" style={{ marginTop: 4 }}>{policy.what}</p>

      <p style={{ margin: "8px 0" }}>
        <b>
          {policy.clock_starts === "Never destroyed"
            ? "Kept indefinitely"
            : `${policy.keep_years} years`}
        </b>
        {policy.clock_starts !== "Never destroyed" && ` from: ${policy.clock_starts.toLowerCase()}`}
      </p>

      {policy.authority && (
        <p className="lock" style={{ marginTop: 0 }}>{policy.authority}</p>
      )}

      {saveState.error && <div className="alert bad">{saveState.error}</div>}
      {saveState.ok && <div className="alert ok">{saveState.ok}</div>}
      {confState.error && <div className="alert bad">{confState.error}</div>}
      {confState.ok && <div className="alert ok">{confState.ok}</div>}

      {!policy.confirmed && (
        <div className="alert" style={{ marginTop: 8 }}>
          Nothing under this policy will ever be reported as due until somebody has checked this
          period against the rule above and confirmed it.
        </div>
      )}

      <div className="row2" style={{ marginTop: 8, alignItems: "center" }}>
        <form action={confirm}>
          <input type="hidden" name="key" value={policy.key} />
          <input type="hidden" name="confirmed" value={policy.confirmed ? "yes" : "no"} />
          <button className={policy.confirmed ? "btn" : "btn gold"} disabled={confirming}>
            {policy.confirmed ? "Withdraw the confirmation" : "I have checked this — confirm"}
          </button>
        </form>
        <button type="button" className="btn" onClick={() => setOpen((v) => !v)}>
          {open ? "Cancel" : "Change the period"}
        </button>
      </div>

      {open && (
        <form action={save} style={{ marginTop: 10 }}>
          <input type="hidden" name="key" value={policy.key} />
          <label className="field" style={{ maxWidth: 160 }}>
            Years
            <input name="keep_years" type="number" step="0.5" defaultValue={policy.keep_years} />
          </label>
          <label className="field">
            Why this number
            <textarea name="authority" rows={3} defaultValue={policy.authority} />
          </label>
          <button className="btn gold" disabled={saving}>
            {saving ? "Saving…" : "Save"}
          </button>
          {policy.confirmed && (
            <p className="lock" style={{ marginBottom: 0 }}>
              Changing the period withdraws the confirmation — a number nobody has checked is a
              number nobody has checked.
            </p>
          )}
        </form>
      )}
    </div>
  );
}

/** Place a hold, and end one. */
function Holds({ holds, closed }: { holds: Hold[]; closed: Row[] }) {
  const [placeState, place, placing] = useActionState(placeHold, initial);
  const [liftState, lift, lifting] = useActionState(liftHold, initial);

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3 style={{ marginTop: 0 }}>Legal holds</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        A record under hold is not due for anything, whatever the schedule says, and cannot be
        recorded as destroyed. The database refuses it, not this screen.
      </p>

      {placeState.error && <div className="alert bad">{placeState.error}</div>}
      {placeState.ok && <div className="alert ok">{placeState.ok}</div>}
      {liftState.error && <div className="alert bad">{liftState.error}</div>}
      {liftState.ok && <div className="alert ok">{liftState.ok}</div>}

      {holds.length === 0 && <div className="empty">No record is under hold.</div>}

      {holds.map((h) => (
        <div key={h.id} className="noteitem">
          <div className="meta">
            <b style={{ color: "var(--ink)" }}>
              {closed.find((c) => c.client_id === h.client_id)?.name ?? "A client"}
            </b>{" "}
            · held by {h.placed_by_name || "—"} on {stamp(h.placed_at)}
          </div>
          {h.reason}
          <form action={lift} style={{ marginTop: 8 }}>
            <input type="hidden" name="hold_id" value={h.id} />
            <div className="row2" style={{ alignItems: "flex-end" }}>
              <label className="field" style={{ flex: 1 }}>
                Why it is being lifted
                <input name="lifted_reason" placeholder="The audit closed on…" />
              </label>
              <button className="btn" disabled={lifting}>Lift</button>
            </div>
          </form>
        </div>
      ))}

      <form action={place} style={{ marginTop: 12 }}>
        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field" style={{ flex: 1 }}>
            Hold a client's record
            <select name="client_id" defaultValue="">
              <option value="">Choose a closed record…</option>
              {closed
                .filter((c) => !c.on_hold)
                .map((c) => (
                  <option key={c.client_id} value={c.client_id}>
                    {c.name} — closed {date(c.closed_on)}
                  </option>
                ))}
            </select>
          </label>
          <label className="field" style={{ flex: 2 }}>
            Why
            <input name="reason" placeholder="Records request from the client's attorney, 12 Sep" />
          </label>
          <button className="btn gold" disabled={placing}>Place hold</button>
        </div>
      </form>
    </div>
  );
}

/** What has passed its period, and what to do about it. */
function DueList({ rows }: { rows: Row[] }) {
  const [state, act, pending] = useActionState(recordDisposition, initial);

  const due = rows.filter((r) => r.due && !r.disposed_at);
  const held = rows.filter((r) => r.on_hold);
  const undated = rows.filter((r) => !r.closed_on);

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3 style={{ marginTop: 0 }}>Past its period</h3>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {due.length === 0 && (
        <div className="empty">
          Nothing has passed its retention period.
          {rows.some((r) => !r.policy_confirmed) &&
            " The client record period has not been confirmed, so nothing can."}
        </div>
      )}

      {due.map((r) => (
        <div key={r.client_id} className="noteitem">
          <div className="meta">
            <b style={{ color: "var(--ink)" }}>{r.name}</b> · closed {date(r.closed_on)} · period
            ended {date(r.keep_until)}
          </div>
          <form action={act} style={{ marginTop: 8 }}>
            <input type="hidden" name="client_id" value={r.client_id} />
            <div className="row2" style={{ alignItems: "flex-end" }}>
              <label className="field" style={{ maxWidth: 220 }}>
                What was decided
                <select name="action" defaultValue="Reviewed — no change">
                  <option>Reviewed — no change</option>
                  <option>Kept longer</option>
                  <option>Destroyed</option>
                </select>
              </label>
              <label className="field" style={{ flex: 1 }}>
                And why
                <input name="reason" placeholder="Paper file shredded 12 Sep; CRM record kept" />
              </label>
              <button className="btn" disabled={pending}>Record it</button>
            </div>
          </form>
        </div>
      ))}

      {(held.length > 0 || undated.length > 0) && (
        <p className="lock" style={{ marginBottom: 0 }}>
          {held.length > 0 && `${held.length} under legal hold. `}
          {undated.length > 0 &&
            `${undated.length} closed without a date in the stage history, so no clock has started — the date would have to be a guess, and a guessed closure date is a guessed destruction date.`}
        </p>
      )}
    </div>
  );
}

export function RetentionView({
  policies,
  rows,
  holds,
  dispositions,
}: {
  policies: Policy[];
  rows: Row[];
  holds: Hold[];
  dispositions: Disposition[];
}) {
  return (
    <>
      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>Nothing here destroys anything</h3>
        <p style={{ margin: 0 }}>
          There is no job, no trigger and no timer. This screen says how long records are kept,
          which have passed that point, and what was decided about each one. Destroying a record is
          something a person does, and this is where they write down that they did it.
        </p>
      </div>

      <DueList rows={rows} />
      <Holds holds={holds} closed={rows} />

      <h2 className="h1" style={{ fontSize: 20, marginTop: 22 }}>The schedule</h2>
      {policies.map((p) => (
        <PolicyCard key={p.key} policy={p} />
      ))}

      <h2 className="h1" style={{ fontSize: 20, marginTop: 22 }}>What has been decided</h2>
      <div className="card" style={{ marginTop: 12 }}>
        {dispositions.length === 0 ? (
          <div className="empty">Nothing has been disposed of or reviewed yet.</div>
        ) : (
          <table className="t">
            <thead>
              <tr>
                <th>When</th>
                <th>Record</th>
                <th>Decision</th>
                <th>Why</th>
                <th>By</th>
              </tr>
            </thead>
            <tbody>
              {dispositions.map((d) => (
                <tr key={d.id}>
                  <td>{stamp(d.disposed_at)}</td>
                  <td>{d.client_name}</td>
                  <td>{d.action}</td>
                  <td>{d.reason}</td>
                  <td>{d.decided_by_name}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p className="lock" style={{ marginBottom: 0 }}>
          Append-only. Nothing here can be edited or removed, including by Admin.
        </p>
      </div>
    </>
  );
}
