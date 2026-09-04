"use client";

import { useActionState } from "react";
import { addTask, toggleTask, type DetailState } from "./actions";
import { today } from "@/lib/constants";

const initial: DetailState = { error: null, ok: null };

export type TaskRow = {
  id: string;
  title: string;
  due: string | null;
  status: string;
  done_at: string | null;
  assigned_name: string;
  system_generated: boolean;
};

type Option = { id: string; name: string };

function TaskToggle({ clientId, task }: { clientId: string; task: TaskRow }) {
  const [state, action, pending] = useActionState(toggleTask, initial);
  const open = task.status === "Open";
  const overdue = open && task.due && task.due < today();

  return (
    <div className={"taskrow" + (open ? "" : " done")}>
      <form action={action}>
        <input type="hidden" name="id" value={clientId} />
        <input type="hidden" name="task_id" value={task.id} />
        <input type="hidden" name="open" value={open ? "true" : "false"} />
        <button
          className="btn ghost"
          type="submit"
          disabled={pending}
          style={{ padding: "2px 10px" }}
          aria-label={open ? "Mark done" : "Reopen"}
        >
          {open ? "○" : "✓"}
        </button>
      </form>

      <span style={{ flex: 1 }}>
        {task.title}
        {task.system_generated && (
          <span className="chip" style={{ marginLeft: 6 }}>
            auto
          </span>
        )}
      </span>

      <span style={{ color: overdue ? "var(--bad)" : "var(--muted)", fontSize: 12 }}>
        {open ? (task.due ? `due ${task.due}` : "no due date") : `done ${task.done_at ?? ""}`}
      </span>
      <span style={{ color: "var(--muted)", fontSize: 12, minWidth: 110 }}>
        {task.assigned_name || "—"}
      </span>

      {state.error && (
        <span style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</span>
      )}
    </div>
  );
}

export function TasksTab({
  clientId,
  tasks,
  staff,
  myId,
}: {
  clientId: string;
  tasks: TaskRow[];
  staff: Option[];
  myId: string;
}) {
  const [state, action, pending] = useActionState(addTask, initial);

  const open = tasks.filter((t) => t.status === "Open");
  const done = tasks.filter((t) => t.status !== "Open");

  return (
    <>
      <div className="card" style={{ marginBottom: 12 }}>
        {state.error && <div className="alert bad">{state.error}</div>}
        {state.ok && <div className="alert ok">{state.ok}</div>}

        <form action={action} className="row2">
          <input type="hidden" name="id" value={clientId} />
          <label className="field" style={{ flex: 2 }}>
            Task
            <input name="title" placeholder="What needs doing" required />
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Due
            <input name="due" type="date" defaultValue={today()} />
          </label>
          <label className="field" style={{ maxWidth: 200 }}>
            Assign to
            <select name="assigned_staff_id" defaultValue={myId}>
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

      {tasks.length === 0 && <div className="empty">No tasks for this client.</div>}

      {open.map((t) => (
        <TaskToggle key={t.id} clientId={clientId} task={t} />
      ))}

      {done.length > 0 && (
        <>
          <h3 style={{ fontSize: 13, margin: "18px 0 4px", color: "var(--muted)" }}>
            Completed
          </h3>
          {done.map((t) => (
            <TaskToggle key={t.id} clientId={clientId} task={t} />
          ))}
        </>
      )}
    </>
  );
}
