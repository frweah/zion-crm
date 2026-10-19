"use client";

import { useActionState, useState } from "react";
import { DataTable } from "../data-table";
import {
  addLine,
  editLine,
  removeLine,
  pasteReport,
  saveBottlenecks,
  submitDay,
  reopenDay,
  type DayState,
} from "./actions";
import { STATUSES } from "./day";

const initial: DayState = { error: null, ok: null };

export type DayLine = {
  id: string;
  status: string;
  description: string;
  notes: string;
  client_id: string | null;
  carried_from: string | null;
  sort_order: number;
};

type Client = { id: string; name: string };

function Message({ state }: { state: DayState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

/**
 * The panel for changing one line.
 *
 * Beneath the list rather than inside it: the list of a day's tasks is a list
 * of records and so is the one DataTable, which cannot hold a form in a row.
 * Choosing a line opens this; saving closes it.
 */
function LineEditor({
  line,
  clients,
  onDone,
}: {
  line: DayLine;
  clients: Client[];
  onDone: () => void;
}) {
  const [state, action, pending] = useActionState(editLine, initial);
  const [gone, remove, removing] = useActionState(removeLine, initial);

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <h4 style={{ marginTop: 0 }}>Changing a line</h4>
      <Message state={state} />
      <Message state={gone} />
      <form action={action} className="row2" style={{ alignItems: "flex-end", gap: 8 }}>
        <input type="hidden" name="line_id" value={line.id} />
        <label className="field" style={{ maxWidth: 150 }}>
          Status
          <select name="status" defaultValue={line.status}>
            {STATUSES.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </label>
        <label className="field" style={{ flex: 2 }}>
          Description
          <input name="description" defaultValue={line.description} required />
        </label>
        <label className="field" style={{ flex: 2 }}>
          Notes
          <input name="notes" defaultValue={line.notes} />
        </label>
        <label className="field" style={{ maxWidth: 200 }}>
          Client
          <select name="client_id" defaultValue={line.client_id ?? ""}>
            <option value="">Not about a client</option>
            {clients.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "…" : "Save"}
        </button>
        <button className="btn ghost" type="button" onClick={onDone}>
          Done
        </button>
      </form>
      <form action={remove} style={{ marginTop: 6 }}>
        <input type="hidden" name="line_id" value={line.id} />
        <button className="btn ghost" type="submit" disabled={removing}>
          {removing ? "…" : "Remove this line"}
        </button>
      </form>
    </div>
  );
}

export function DayForm({
  day,
  dayId,
  mine,
  readOnly,
  submittedAt,
  header,
  lines,
  bottlenecks,
  actionsTaken,
  clients,
  events,
}: {
  day: string;
  dayId: string | null;
  mine: boolean;
  readOnly: boolean;
  submittedAt: string | null;
  header: { name: string; role: string; manager: string };
  lines: DayLine[];
  bottlenecks: string;
  actionsTaken: string;
  clients: Client[];
  events: { action: string; reason: string; at: string }[];
}) {
  const [added, add, adding] = useActionState(addLine, initial);
  const [pasted, paste, pasting] = useActionState(pasteReport, initial);
  const [saved, save, saving] = useActionState(saveBottlenecks, initial);
  const [sent, submit, submitting] = useActionState(submitDay, initial);
  const [reopened, reopen, reopening] = useActionState(reopenDay, initial);
  const [showPaste, setShowPaste] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);

  const locked = Boolean(submittedAt);
  const editable = mine && !locked;
  const sameDay = day === new Date().toISOString().slice(0, 10);
  const chosen = lines.find((l) => l.id === editing) ?? null;

  return (
    <>
      {/* ── the header the template has ─────────────────────── */}
      <div className="card">
        <div className="row2" style={{ gap: 24, flexWrap: "wrap" }}>
          <div>
            <span className="sub">Name of the Employee</span>
            <div>{header.name}</div>
          </div>
          <div>
            <span className="sub">Department/Agency</span>
            <div>{header.role || "—"}</div>
          </div>
          <div>
            <span className="sub">Date Prepared</span>
            <div>
              {new Date(`${day}T00:00:00`).toLocaleDateString("en-US", {
                month: "long",
                day: "numeric",
                year: "numeric",
              })}
            </div>
          </div>
          <div>
            <span className="sub">Assigned Manager/Team Leader</span>
            <div>{header.manager || "—"}</div>
          </div>
        </div>
        {locked && (
          <p className="lock" style={{ margin: "10px 0 0" }}>
            Submitted. {mine && sameDay ? "It can be reopened today." : "It is on the record as it stands."}
          </p>
        )}
      </div>

      <Message state={added} />
      <Message state={pasted} />
      <Message state={saved} />
      <Message state={sent} />
      <Message state={reopened} />

      {/* ── TASKS LIST ──────────────────────────────────────── */}
      <div className="card" style={{ marginTop: 14 }}>
        <div className="row2" style={{ justifyContent: "space-between", alignItems: "center" }}>
          <h3 style={{ margin: 0 }}>Tasks list</h3>
          {editable && (
            <button className="btn" type="button" onClick={() => setShowPaste(!showPaste)}>
              {showPaste ? "Cancel" : "Paste a report"}
            </button>
          )}
        </div>

        {editable && showPaste && (
          <form action={paste} style={{ marginTop: 10 }}>
            <input type="hidden" name="day" value={day} />
            <label className="field">
              Paste your day
              <textarea
                name="pasted"
                rows={6}
                placeholder={"- Rang the counselor about the authorization\n- [Pending] Chase the signed intake"}
              />
            </label>
            <p className="lock" style={{ margin: "6px 0" }}>
              One task a line, starting with a hyphen. Brackets set the status.
            </p>
            <button className="btn gold" type="submit" disabled={pasting}>
              {pasting ? "Reading…" : "Read it"}
            </button>
          </form>
        )}

        <div style={{ marginTop: 10, border: "1px solid var(--line)", borderRadius: 6 }}>
          <DataTable
            label="task lines"
            columns={[
              { key: "status", label: "Status" },
              { key: "description", label: "Description" },
              { key: "notes", label: "Notes" },
              { key: "actions", label: "", sortable: false },
            ]}
            rows={lines.map((l) => {
              const client = clients.find((c) => c.id === l.client_id);
              return {
                key: l.id,
                text: `${l.status} ${l.description} ${l.notes} ${client?.name ?? ""}`,
                sort: { status: l.status, description: l.description, notes: l.notes },
                cells: {
                  status: (
                    <>
                      <span className="chip">{l.status}</span>
                      {l.carried_from && (
                        <span className="chip" style={{ marginLeft: 4 }}>
                          carried
                        </span>
                      )}
                    </>
                  ),
                  description: (
                    <>
                      {l.description}
                      {client && <span className="sub"> · {client.name}</span>}
                    </>
                  ),
                  notes: <span className="sub">{l.notes}</span>,
                  actions: editable ? (
                    <button
                      className="btn ghost"
                      type="button"
                      onClick={() => setEditing(l.id)}
                      style={{ padding: "2px 10px" }}
                    >
                      Change
                    </button>
                  ) : null,
                },
              };
            })}
            empty="Nothing on the day yet."
          />
        </div>

        {editable && chosen && (
          <LineEditor line={chosen} clients={clients} onDone={() => setEditing(null)} />
        )}

        {editable && (
          <form action={add} className="row2" style={{ alignItems: "flex-end", gap: 8, marginTop: 10 }}>
            <input type="hidden" name="day" value={day} />
            <label className="field" style={{ maxWidth: 150 }}>
              Status
              <select name="status" defaultValue="Complete">
                {STATUSES.map((s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ))}
              </select>
            </label>
            <label className="field" style={{ flex: 2 }}>
              Description
              <input name="description" required placeholder="What was done" />
            </label>
            <label className="field" style={{ flex: 2 }}>
              Notes
              <input name="notes" placeholder="Anything worth saying" />
            </label>
            <label className="field" style={{ maxWidth: 200 }}>
              Client
              <select name="client_id" defaultValue="">
                <option value="">Not about a client</option>
                {clients.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
            </label>
            <button className="btn gold" type="submit" disabled={adding}>
              {adding ? "…" : "Add"}
            </button>
          </form>
        )}
      </div>

      {/* ── BOTTLENECKS ─────────────────────────────────────── */}
      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>Bottlenecks</h3>
        {editable ? (
          <form action={save}>
            <input type="hidden" name="day" value={day} />
            <label className="field">
              What got in the way
              <textarea name="bottlenecks" rows={3} defaultValue={bottlenecks} />
            </label>
            <label className="field">
              Actions taken / suggestions
              <textarea name="actions_taken" rows={3} defaultValue={actionsTaken} />
            </label>
            <button className="btn" type="submit" disabled={saving}>
              {saving ? "…" : "Save"}
            </button>
          </form>
        ) : (
          <>
            <p>{bottlenecks || "None."}</p>
            <h4>Actions taken / suggestions</h4>
            <p>{actionsTaken || "None."}</p>
          </>
        )}
      </div>

      {/* ── submitting ──────────────────────────────────────── */}
      {mine && !locked && (
        <form action={submit} style={{ marginTop: 14 }}>
          <input type="hidden" name="day" value={day} />
          <button className="btn gold" type="submit" disabled={submitting || lines.length === 0}>
            {submitting ? "Submitting…" : "Submit day"}
          </button>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            It goes to your manager, to Admin, and to service@zionvocrehab.com.</p>
        </form>
      )}

      {mine && locked && sameDay && dayId && (
        <form action={reopen} className="row2" style={{ alignItems: "flex-end", gap: 8, marginTop: 14 }}>
          <input type="hidden" name="day_id" value={dayId} />
          <label className="field" style={{ flex: 2 }}>
            Why it is being reopened
            <input name="reason" required placeholder="What needs changing" />
          </label>
          <button className="btn" type="submit" disabled={reopening}>
            {reopening ? "…" : "Reopen"}
          </button>
        </form>
      )}

      {events.length > 0 && (
        <div className="card" style={{ marginTop: 14 }}>
          <h3 style={{ marginTop: 0 }}>History</h3>
          <ul>
            {events.map((e, i) => (
              <li key={i} className="sub">
                {e.action} {new Date(e.at).toLocaleString()}
                {e.reason ? ` — ${e.reason}` : ""}
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  );
}
