"use client";

import { useActionState } from "react";
import { addTask, type DetailState } from "./actions";
import { TaskActions, TaskReopen } from "../../tasks/task-actions";
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

/**
 * A task on the client's record.
 *
 * The two actions come from the same control as Today, Tasks, My day and the
 * Home counters, which is the whole of what changed here: this row used to
 * draw a circle that filled in, offered no way to take a task off the list,
 * and went through an action of its own that wrote the same column.
 */
export function ClientTaskRow({ task }: { task: TaskRow }) {
  const open = task.status === "Open";
  const overdue = open && task.due && task.due < today();

  return (
    <div className={"taskrow" + (open ? "" : " done")}>
      <span style={{ flex: 1 }}>
        {task.title}
        {task.system_generated && (
          <span className="chip" style={{ marginLeft: 6 }}>
            auto
          </span>
        )}
      </span>

      <span style={{ color: overdue ? "var(--bad)" : "var(--muted)", fontSize: "var(--text-sm)" }}>
        {open ? (task.due ? `due ${task.due}` : "no due date") : `done ${task.done_at ?? ""}`}
      </span>
      <span style={{ color: "var(--muted)", fontSize: "var(--text-sm)", minWidth: 110 }}>
        {task.assigned_name || "—"}
      </span>

      {open ? <TaskActions taskId={task.id} compact /> : <TaskReopen taskId={task.id} />}
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
        <ClientTaskRow key={t.id} task={t} />
      ))}

      {done.length > 0 && (
        <>
          <h3 style={{ fontSize: "var(--text-md)", margin: "18px 0 4px", color: "var(--muted)" }}>
            Completed
          </h3>
          {done.map((t) => (
            <ClientTaskRow key={t.id} task={t} />
          ))}
        </>
      )}
    </>
  );
}
