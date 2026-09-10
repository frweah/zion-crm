"use client";

import { useActionState, useState } from "react";
import { offboardStaff, type StaffState } from "./actions";

const initial: StaffState = { error: null, ok: null };

export type ReadinessRow = {
  staff_id: string;
  name: string;
  role: string;
  active: boolean;
  active_clients: number;
  open_tasks: number;
  unsubmitted_hours: number;
  open_statements: number;
  running_timers: number;
  documents_held: number;
  mailbox_connected: number;
};

export type OffboardedRow = {
  staff_id: string;
  last_day: string;
  reason: string;
  successor_id: string | null;
  clients_moved: number;
  tasks_moved: number;
  note: string;
  offboarded_at: string;
};

/**
 * Somebody leaving.
 *
 * Everything still attached to them is on the screen before the button is,
 * because the conversation about an unsubmitted week of hours has to happen
 * while they are still answering their phone. None of it blocks — an account
 * left open until the paperwork is settled is the worse of the two risks.
 */
export function Offboarding({
  people,
  colleagues,
  today,
  offboarded,
  nameOf,
}: {
  people: ReadinessRow[];
  colleagues: { id: string; name: string }[];
  today: string;
  offboarded: OffboardedRow[];
  nameOf: Record<string, string>;
}) {
  const [state, action, pending] = useActionState(offboardStaff, initial);
  const [open, setOpen] = useState<string | null>(null);

  const done = new Map(offboarded.map((o) => [o.staff_id, o]));

  return (
    <>
      <h1 className="h1" style={{ fontSize: 18, marginTop: 26 }}>
        Offboarding
      </h1>
      <p className="sub">
        Reassigning the caseload, closing the loose ends and shutting the account happen together,
        in one step — done separately, the second half gets done on a different day or not at all.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {people.map((p) => {
        const record = done.get(p.staff_id);
        const attached =
          Number(p.active_clients) +
          Number(p.open_tasks) +
          Number(p.open_statements) +
          Number(p.running_timers);

        return (
          <div className="card" key={p.staff_id} style={{ marginBottom: 14 }}>
            <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
              <div>
                <h3 style={{ margin: 0 }}>
                  {p.name}
                  {!p.active && <span className="chip" style={{ marginLeft: 8 }}>left</span>}
                </h3>
                {record ? (
                  <p className="sub" style={{ margin: "4px 0 0" }}>
                    Last day {record.last_day}
                    {record.reason && ` · ${record.reason}`}
                    {record.successor_id && ` · caseload to ${nameOf[record.successor_id] ?? "somebody"}`}
                    {record.clients_moved > 0 && ` · ${record.clients_moved} clients moved`}
                    {record.tasks_moved > 0 && `, ${record.tasks_moved} tasks`}
                  </p>
                ) : (
                  <p className="sub" style={{ margin: "4px 0 0" }}>
                    {attached === 0
                      ? "Nothing attached to them."
                      : "Still attached to them — settle what can be settled first."}
                  </p>
                )}
              </div>

              {p.active && (
                <button
                  className="btn"
                  type="button"
                  onClick={() => setOpen(open === p.staff_id ? null : p.staff_id)}
                >
                  {open === p.staff_id ? "Cancel" : "Offboard"}
                </button>
              )}
            </div>

            {!record && attached > 0 && (
              <table className="t" style={{ marginTop: 8 }}>
                <tbody>
                  {Number(p.active_clients) > 0 && (
                    <tr>
                      <td style={{ width: 200 }}>Active clients</td>
                      <td>
                        <b>{Number(p.active_clients)}</b> — they move to whoever takes over, or
                        become unassigned
                      </td>
                    </tr>
                  )}
                  {Number(p.open_tasks) > 0 && (
                    <tr>
                      <td>Open tasks</td>
                      <td>
                        <b>{Number(p.open_tasks)}</b> — moved with the caseload where somebody
                        takes over
                      </td>
                    </tr>
                  )}
                  {Number(p.unsubmitted_hours) > 0 && (
                    <tr>
                      <td>Hours not on a statement</td>
                      <td style={{ color: "var(--bad)" }}>
                        <b>{Number(p.unsubmitted_hours)}</b> — money they are owed. Settle it
                        before they lose access to submit.
                      </td>
                    </tr>
                  )}
                  {Number(p.open_statements) > 0 && (
                    <tr>
                      <td>Statements waiting</td>
                      <td style={{ color: "var(--bad)" }}>
                        <b>{Number(p.open_statements)}</b> submitted and not yet approved
                      </td>
                    </tr>
                  )}
                  {Number(p.running_timers) > 0 && (
                    <tr>
                      <td>Timer left running</td>
                      <td>Discarded on offboarding — it measures the time since they forgot</td>
                    </tr>
                  )}
                  {Number(p.mailbox_connected) > 0 && (
                    <tr>
                      <td>Outlook connected</td>
                      <td className="lock">
                        Access ends with the account; the mail already logged stays
                      </td>
                    </tr>
                  )}
                  {Number(p.documents_held) > 0 && (
                    <tr>
                      <td>Documents on file</td>
                      <td className="lock">
                        {Number(p.documents_held)} kept — a personnel file outlives the job
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            )}

            {open === p.staff_id && (
              <form action={action} style={{ marginTop: 10 }}>
                <input type="hidden" name="staff_id" value={p.staff_id} />
                <div className="row2">
                  <label className="field" style={{ maxWidth: 170 }}>
                    Last day
                    <input type="date" name="last_day" defaultValue={today} required />
                  </label>
                  <label className="field" style={{ maxWidth: 220 }}>
                    Caseload goes to
                    <select name="successor_id" defaultValue="">
                      <option value="">Nobody — leave unassigned</option>
                      {colleagues
                        .filter((c) => c.id !== p.staff_id)
                        .map((c) => (
                          <option key={c.id} value={c.id}>
                            {c.name}
                          </option>
                        ))}
                    </select>
                  </label>
                  <label className="field" style={{ maxWidth: 200 }}>
                    Reason
                    <input name="reason" placeholder="Resigned, contract ended" />
                  </label>
                  <label className="field" style={{ flex: 2 }}>
                    Note
                    <input name="note" />
                  </label>
                  <button className="btn gold" type="submit" disabled={pending}>
                    {pending ? "Working…" : "Offboard"}
                  </button>
                </div>
                <p className="lock" style={{ margin: "8px 0 0" }}>
                  Their access ends the moment this is saved. Leaving the caseload unassigned is a
                  real choice — unassigned clients are counted on the capacity screen, so they
                  surface rather than disappearing.
                </p>
              </form>
            )}
          </div>
        );
      })}
    </>
  );
}
