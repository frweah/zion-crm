"use client";

import { useState, useActionState } from "react";
import Link from "next/link";
import { createTask, setTaskStatus, type TaskState } from "./actions";
import { answerReminder, type ReminderState } from "./reminder-actions";
import { today, JOB_STATUSES } from "@/lib/constants";

const initial: TaskState = { error: null, ok: null };

export type TaskListRow = {
  id: string;
  title: string;
  due: string | null;
  status: string;
  client_id: string | null;
  client_name: string;
  assigned_name: string;
  system_generated: boolean;
  /** Set when this task was raised by a job, which is what makes it askable. */
  source_match_id: string | null;
  source_kind: string | null;
};

const reminderInitial: ReminderState = { error: null, ok: null };

/**
 * Closing a reminder with what came of it.
 *
 * Shown instead of the plain tick for interview and follow-up reminders,
 * because at that moment somebody knows how it went and will not go looking
 * for the job to say so.
 */
function ReminderPrompt({ task }: { task: TaskListRow }) {
  const [state, action, pending] = useActionState(answerReminder, reminderInitial);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button
        className="btn ghost"
        type="button"
        onClick={() => setOpen(true)}
        style={{ padding: "1px 9px", lineHeight: 1.4 }}
        title="How did it go?"
      >
        ○
      </button>
    );
  }

  return (
    <div className="card" style={{ padding: 12, minWidth: 260 }}>
      <b style={{ fontSize: 13 }}>How did it go?</b>
      {state.error && <div className="alert bad">{state.error}</div>}
      <form action={action}>
        <input type="hidden" name="task_id" value={task.id} />
        <input type="hidden" name="client_id" value={task.client_id ?? ""} />
        <label className="field">
          Where the job stands now
          <select name="status" defaultValue="">
            <option value="">Leave it where it is</option>
            {JOB_STATUSES.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          In a line
          <input name="outcome" placeholder="What happened" />
        </label>
        <div className="row2" style={{ gap: 6 }}>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Done"}
          </button>
          <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
            Cancel
          </button>
        </div>
        <p className="lock" style={{ marginBottom: 0 }}>
          Leaving the status alone is a real answer — sometimes nothing has changed yet.
        </p>
      </form>
    </div>
  );
}

type Option = { id: string; name: string };

function StatusBox({ task }: { task: TaskListRow }) {
  const [state, action, pending] = useActionState(setTaskStatus, initial);
  const open = task.status === "Open";

  // A reminder raised by a job closes by saying what came of it.
  if (open && task.source_match_id) return <ReminderPrompt task={task} />;

  return (
    <form action={action}>
      <input type="hidden" name="task_id" value={task.id} />
      <input type="hidden" name="open" value={open ? "true" : "false"} />
      <button
        className="btn ghost"
        type="submit"
        disabled={pending}
        style={{ padding: "1px 9px", lineHeight: 1.4 }}
        title={state.error ?? (open ? "Mark done" : "Reopen")}
      >
        {open ? "○" : "✓"}
      </button>
      {state.error && (
        <div style={{ color: "var(--bad)", fontSize: 11, maxWidth: 200 }}>{state.error}</div>
      )}
    </form>
  );
}

export function TasksView({
  tasks,
  clients,
  staff,
  isAdmin,
  myId,
  scopeNote,
}: {
  tasks: TaskListRow[];
  clients: Option[];
  staff: Option[];
  isAdmin: boolean;
  myId: string;
  scopeNote: string;
}) {
  const [showDone, setShowDone] = useState(false);
  const [state, action, pending] = useActionState(createTask, initial);

  const list = tasks
    .filter((t) => showDone || t.status === "Open")
    .sort((a, b) => (a.due ?? "9999").localeCompare(b.due ?? "9999"));

  const doneCount = tasks.filter((t) => t.status !== "Open").length;

  return (
    <>
      <h1 className="h1">Tasks</h1>
      <p className="sub">{scopeNote}</p>

      <div className="card" style={{ marginBottom: 14 }}>
        {state.error && <div className="alert bad">{state.error}</div>}
        {state.ok && <div className="alert ok">{state.ok}</div>}

        <form action={action} className="row2">
          <label className="field" style={{ flex: 2 }}>
            New task
            <input name="title" placeholder="What needs doing" required />
          </label>
          <label className="field">
            Client
            <select name="client_id" defaultValue="">
              <option value="">— none —</option>
              {clients.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Due
            <input name="due" type="date" defaultValue={today()} />
          </label>
          <label className="field" style={{ maxWidth: 200 }}>
            Assign to
            <select name="assigned_staff_id" defaultValue={myId} disabled={!isAdmin}>
              {staff.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Adding…" : "Add task"}
          </button>
        </form>
      </div>

      <label style={{ fontSize: 12 }}>
        <input
          type="checkbox"
          style={{ width: "auto", marginRight: 6 }}
          checked={showDone}
          onChange={(e) => setShowDone(e.target.checked)}
        />
        Show completed ({doneCount})
      </label>

      <div className="card" style={{ padding: 0, marginTop: 8 }}>
        <table className="t">
          <thead>
            <tr>
              <th style={{ width: 40 }} />
              <th>Task</th>
              <th>Client</th>
              <th>Assigned</th>
              <th>Due</th>
            </tr>
          </thead>
          <tbody>
            {list.length === 0 && (
              <tr>
                <td colSpan={5} className="empty">
                  No open tasks.
                </td>
              </tr>
            )}
            {list.map((t) => {
              const overdue = t.status === "Open" && t.due && t.due < today();
              return (
                <tr key={t.id}>
                  <td>
                    <StatusBox task={t} />
                  </td>
                  <td
                    style={{
                      textDecoration: t.status === "Done" ? "line-through" : "none",
                      color: t.status === "Done" ? "var(--muted)" : undefined,
                    }}
                  >
                    {t.title}
                    {t.system_generated && (
                      <span className="chip" style={{ marginLeft: 6 }}>
                        auto
                      </span>
                    )}
                  </td>
                  <td>
                    {t.client_id ? (
                      <Link href={`/clients/${t.client_id}`} style={{ color: "var(--teal)" }}>
                        {t.client_name}
                      </Link>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td>{t.assigned_name || "—"}</td>
                  <td>
                    <span className={"chip " + (overdue ? "bad" : "")}>{t.due ?? "—"}</span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </>
  );
}
