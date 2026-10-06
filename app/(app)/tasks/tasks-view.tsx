"use client";

import { useState, useActionState } from "react";
import Link from "next/link";
import { createTask, setTaskStatus, addStep, commentOnTask, setTaskRepeat, type TaskState } from "./actions";
import { answerReminder, type ReminderState } from "./reminder-actions";
import { today, JOB_STATUSES } from "@/lib/constants";
import { PageHead } from "../page-head";
import { DataTable } from "../data-table";
import { TaskDue, TaskWho } from "../task-inline";

const initial: TaskState = { error: null, ok: null };

export type TaskListRow = {
  id: string;
  title: string;
  due: string | null;
  status: string;
  client_id: string | null;
  client_name: string;
  assigned_name: string;
  assigned_staff_id: string | null;
  /** The task this is a step of (0138). */
  parent_id: string | null;
  /** How often it comes round: week, month, quarter, 90 days, year. */
  repeat_every: string | null;
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
      <b style={{ fontSize: "var(--text-md)" }}>How did it go?</b>
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
        <div style={{ color: "var(--bad)", fontSize: "var(--text-xs)", maxWidth: 200 }}>{state.error}</div>
      )}
    </form>
  );
}

/**
 * A task, its steps, and what has been said about it (Design language, §2).
 *
 * The steps sit under the task as a checklist rather than loose among the
 * other tasks, because "send the quarterly report" is six things and six
 * unrelated rows is how one of them goes missing. Each step is a task, so
 * ticking one is the same act with the same rules.
 */
function TaskTitle({ task, steps }: { task: TaskListRow; steps: TaskListRow[] }) {
  const [open, setOpen] = useState(false);
  const [stepState, stepAction] = useActionState(addStep, initial);
  const [sayState, sayAction] = useActionState(commentOnTask, initial);
  const [repeatState, repeatAction] = useActionState(setTaskRepeat, initial);
  const finished = steps.filter((s) => s.status !== "Open").length;

  return (
    <div className="checklist">
      <span className={task.status === "Done" ? "checklist-done" : undefined}>
        {task.title}
        {task.system_generated && <span className="chip" style={{ marginLeft: 6 }}>auto</span>}
        {task.repeat_every && <span className="chip" style={{ marginLeft: 6 }}>every {task.repeat_every}</span>}
      </span>

      <button className="row-link" type="button" onClick={() => setOpen((v) => !v)}>
        {steps.length > 0 ? `${finished} of ${steps.length} steps` : open ? "Hide" : "Steps and notes"}
      </button>

      {steps.length > 0 && (
        <ul className="checklist-steps">
          {steps.map((s) => (
            <li key={s.id} className={s.status === "Open" ? undefined : "checklist-done"}>
              <StatusBox task={s} />
              <span>{s.title}</span>
            </li>
          ))}
        </ul>
      )}

      {open && (
        <div className="checklist-more">
          <form action={stepAction} className="row2" style={{ gap: 6 }}>
            <input type="hidden" name="parent_id" value={task.id} />
            <input name="title" placeholder="Add a step" aria-label="Add a step" required />
            <button className="row-link" type="submit">Add</button>
          </form>
          {stepState.error && <div className="lock">{stepState.error}</div>}

          <form action={sayAction} className="row2" style={{ gap: 6 }}>
            <input type="hidden" name="task_id" value={task.id} />
            <input name="said" placeholder="Add a note" aria-label="Add a note" required />
            <button className="row-link" type="submit">Say it</button>
          </form>
          {sayState.error && <div className="lock">{sayState.error}</div>}

          <form action={repeatAction} className="row2" style={{ gap: 6, alignItems: "center" }}>
            <input type="hidden" name="task_id" value={task.id} />
            <label className="lock" htmlFor={`repeat-${task.id}`}>Comes round</label>
            <select id={`repeat-${task.id}`} name="repeat_every" defaultValue={task.repeat_every ?? ""}>
              <option value="">once</option>
              <option value="week">every week</option>
              <option value="month">every month</option>
              <option value="quarter">every quarter</option>
              <option value="90 days">every 90 days</option>
              <option value="year">every year</option>
            </select>
            <button className="row-link" type="submit">Save</button>
          </form>
          {repeatState.error && <div className="lock">{repeatState.error}</div>}
        </div>
      )}
    </div>
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

  // A checklist rather than a table (Design language, §2): a finished row
  // strikes and drops to the bottom, and a step sits under the task it
  // belongs to rather than loose among the others.
  const steps = new Map<string, TaskListRow[]>();
  for (const t of tasks) {
    if (!t.parent_id) continue;
    if (!steps.has(t.parent_id)) steps.set(t.parent_id, []);
    steps.get(t.parent_id)!.push(t);
  }
  const done = (t: TaskListRow) => (t.status === "Open" ? 0 : 1);
  const list = tasks
    .filter((t) => !t.parent_id)
    .filter((t) => showDone || t.status === "Open" || (steps.get(t.id) ?? []).some((s) => s.status === "Open"))
    .sort((a, b) => done(a) - done(b) || (a.due ?? "9999").localeCompare(b.due ?? "9999"));

  const doneCount = tasks.filter((t) => t.status !== "Open").length;

  return (
    <>
      <PageHead title="Tasks" context={scopeNote} />

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

      <label style={{ fontSize: "var(--text-sm)" }}>
        <input
          type="checkbox"
          style={{ width: "auto", marginRight: 6 }}
          checked={showDone}
          onChange={(e) => setShowDone(e.target.checked)}
        />
        Show completed ({doneCount})
      </label>

      {/* The tick (or "How did it go?") is a cell of its own, so the rest of the row can sort and filter. */}
      <div className="card" style={{ padding: 0, marginTop: 8 }}>
        <DataTable
          label="tasks"
          sortBy
          columns={[
            { key: "done", label: "", sortable: false, width: 40 },
            { key: "title", label: "Task" },
            { key: "client", label: "Client" },
            { key: "assigned", label: "Assigned" },
            { key: "due", label: "Due" },
          ]}
          rows={list.map((t) => {
            const overdue = t.status === "Open" && t.due && t.due < today();
            return {
              key: t.id,
              sort: {
                title: t.title,
                client: t.client_name,
                assigned: t.assigned_name,
                due: t.due,
              },
              text: [t.title, t.client_name, t.assigned_name, t.due, t.system_generated ? "auto" : ""]
                .filter(Boolean)
                .join(" "),
              cells: {
                done: <StatusBox task={t} />,
                title: (
                  <TaskTitle task={t} steps={steps.get(t.id) ?? []} />
                ),
                client: t.client_id ? (
                  <Link href={`/clients/${t.client_id}`} style={{ color: "var(--teal)" }}>
                    {t.client_name}
                  </Link>
                ) : (
                  "—"
                ),
                assigned: <TaskWho taskId={t.id} staffId={t.assigned_staff_id ?? null} staff={staff} />,
                due: <TaskDue taskId={t.id} due={t.due} overdue={Boolean(overdue)} />,
              },
            };
          })}
          empty={showDone ? "No tasks." : "No open tasks."}
        />
      </div>
    </>
  );
}
