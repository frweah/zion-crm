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
import { DataTable } from "../../data-table";

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

/**
 * One period, and whether anybody has checked it.
 *
 * An item in the schedule's list rather than a card of its own: every period
 * carries its own forms, and a stack of cards reads as a dashboard of equals.
 */
function PolicyItem({ policy }: { policy: Policy }) {
  const [saveState, save, saving] = useActionState(savePolicy, initial);
  const [confState, confirm, confirming] = useActionState(confirmPolicy, initial);
  const [open, setOpen] = useState(false);

  return (
    <div className="list-item">
      <div className="row2" style={{ alignItems: "baseline" }}>
        <b>{policy.label}</b>
        {policy.confirmed ? (
          <span className="chip">
            Confirmed{policy.confirmed_at ? ` ${stamp(policy.confirmed_at)}` : ""}
          </span>
        ) : (
          <span className="chip bad">Not checked by anybody</span>
        )}
      </div>
      <p className="sub" style={{ margin: "4px 0 0" }}>{policy.what}</p>

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
    <>
      <h3 style={{ marginTop: 22 }}>Legal holds</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        A record under hold is not due for anything, whatever the schedule says, and cannot be
        recorded as destroyed. The database refuses it, not this screen.
      </p>

      {placeState.error && <div className="alert bad">{placeState.error}</div>}
      {placeState.ok && <div className="alert ok">{placeState.ok}</div>}
      {liftState.error && <div className="alert bad">{liftState.error}</div>}
      {liftState.ok && <div className="alert ok">{liftState.ok}</div>}

      <div className="card" style={{ padding: 0, marginBottom: 12 }}>
        <DataTable
          label="holds"
          columns={[
            { key: "client", label: "Client" },
            { key: "by", label: "Held by" },
            { key: "on", label: "Placed" },
            { key: "why", label: "Why" },
            { key: "lift", label: "", sortable: false },
          ]}
          rows={holds.map((h) => {
            const name = closed.find((c) => c.client_id === h.client_id)?.name ?? "A client";
            return {
              key: h.id,
              sort: { client: name, by: h.placed_by_name, on: h.placed_at, why: h.reason },
              text: [name, h.placed_by_name, h.reason].filter(Boolean).join(" "),
              cells: {
                client: <b>{name}</b>,
                by: h.placed_by_name || "—",
                on: <span style={{ whiteSpace: "nowrap" }}>{stamp(h.placed_at)}</span>,
                why: h.reason,
                lift: (
                  <form action={lift} className="row2" style={{ alignItems: "flex-end" }}>
                    <input type="hidden" name="hold_id" value={h.id} />
                    <label className="field" style={{ flex: 1, minWidth: 180 }}>
                      Why it is being lifted
                      <input name="lifted_reason" placeholder="The audit closed on…" />
                    </label>
                    <button className="btn" disabled={lifting}>Lift</button>
                  </form>
                ),
              },
            };
          })}
          empty="No record is under hold."
        />
      </div>

      <form action={place} className="card">
        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field" style={{ flex: 1 }}>
            Hold a client&apos;s record
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
    </>
  );
}

/** What has passed its period, and what to do about it. */
function DueList({ rows }: { rows: Row[] }) {
  const [state, act, pending] = useActionState(recordDisposition, initial);

  const due = rows.filter((r) => r.due && !r.disposed_at);
  const held = rows.filter((r) => r.on_hold);
  const undated = rows.filter((r) => !r.closed_on);

  return (
    <>
      <h3 style={{ marginTop: 22 }}>Past its period</h3>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {due.length === 0 ? (
        <p className="empty">
          Nothing has passed its retention period.
          {rows.some((r) => !r.policy_confirmed) &&
            " The client record period has not been confirmed, so nothing can."}
        </p>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="records past their period"
            columns={[
              { key: "client", label: "Client" },
              { key: "closed", label: "Closed" },
              { key: "ended", label: "Period ended" },
              { key: "decide", label: "What was decided", sortable: false },
            ]}
            rows={due.map((r) => ({
              key: r.client_id,
              sort: { client: r.name, closed: r.closed_on, ended: r.keep_until },
              text: r.name,
              cells: {
                client: <b>{r.name}</b>,
                closed: <span style={{ whiteSpace: "nowrap" }}>{date(r.closed_on)}</span>,
                ended: <span style={{ whiteSpace: "nowrap" }}>{date(r.keep_until)}</span>,
                decide: (
                  <form action={act} className="row2" style={{ alignItems: "flex-end" }}>
                    <input type="hidden" name="client_id" value={r.client_id} />
                    <label className="field" style={{ maxWidth: 220 }}>
                      What was decided
                      <select name="action" defaultValue="Reviewed — no change">
                        <option>Reviewed — no change</option>
                        <option>Kept longer</option>
                        <option>Destroyed</option>
                      </select>
                    </label>
                    <label className="field" style={{ flex: 1, minWidth: 180 }}>
                      And why
                      <input name="reason" placeholder="Paper file shredded 12 Sep; CRM record kept" />
                    </label>
                    <button className="btn" disabled={pending}>Record it</button>
                  </form>
                ),
              },
            }))}
            empty="Nothing has passed its retention period."
          />
        </div>
      )}

      {(held.length > 0 || undated.length > 0) && (
        <p className="lock" style={{ marginBottom: 0 }}>
          {held.length > 0 && `${held.length} under legal hold. `}
          {undated.length > 0 &&
            `${undated.length} closed without a date in the stage history, so no clock has started — the date would have to be a guess, and a guessed closure date is a guessed destruction date.`}
        </p>
      )}
    </>
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

      <h3 style={{ marginTop: 22 }}>The schedule</h3>
      {policies.length === 0 ? (
        <p className="empty">No retention period has been set up.</p>
      ) : (
        <div className="list">
          {policies.map((p) => (
            <PolicyItem key={p.key} policy={p} />
          ))}
        </div>
      )}

      <h3 style={{ marginTop: 22 }}>What has been decided</h3>
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="decisions"
          columns={[
            { key: "when", label: "When" },
            { key: "record", label: "Record" },
            { key: "decision", label: "Decision" },
            { key: "why", label: "Why" },
            { key: "by", label: "By" },
          ]}
          rows={dispositions.map((d) => ({
            key: String(d.id),
            sort: { when: d.disposed_at },
            cells: {
              when: stamp(d.disposed_at),
              record: d.client_name,
              decision: d.action,
              why: d.reason,
              by: d.decided_by_name,
            },
          }))}
          empty="Nothing has been disposed of or reviewed yet."
        />
        <p className="lock" style={{ margin: 0, padding: "10px 14px 14px" }}>
          Append-only. Nothing here can be edited or removed, including by Admin.
        </p>
      </div>
    </>
  );
}
