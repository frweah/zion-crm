"use client";

import { useActionState, useEffect, useRef } from "react";
import { setTaskDue, setTaskAssignee, type TaskState } from "./tasks/actions";

const initial: TaskState = { error: null, ok: null };

/**
 * A task's date and its owner, changed where the task is listed.
 *
 * Every list of tasks uses these two, so the gesture is the same on the
 * dashboard, on Tasks, and on a client's record: change the field, and it is
 * saved. No Save button, because a button nobody presses is a date that goes
 * stale (Rei, Oct 2026).
 *
 * What the rules refuse, the control says so and puts back what was there -
 * a field that silently keeps a value the database rejected is worse than one
 * that never offered to change it.
 */
export function TaskDue({ taskId, due, overdue }: { taskId: string; due: string | null; overdue?: boolean }) {
  const [state, action] = useActionState(setTaskDue, initial);
  const form = useRef<HTMLFormElement>(null);
  const field = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (state.error && field.current) field.current.value = due ?? "";
  }, [state.error, due]);

  return (
    <form action={action} ref={form} className="inline-edit">
      <input type="hidden" name="task_id" value={taskId} />
      <input
        ref={field}
        type="date"
        name="due"
        defaultValue={due ?? ""}
        aria-label="Due date"
        className={overdue ? "due overdue" : "due"}
        onChange={() => form.current?.requestSubmit()}
      />
      {state.error && <span className="inline-edit-error">{state.error}</span>}
    </form>
  );
}

export function TaskWho({
  taskId,
  staffId,
  staff,
}: {
  taskId: string;
  staffId: string | null;
  staff: { id: string; name: string }[];
}) {
  const [state, action] = useActionState(setTaskAssignee, initial);
  const form = useRef<HTMLFormElement>(null);
  const field = useRef<HTMLSelectElement>(null);

  useEffect(() => {
    if (state.error && field.current) field.current.value = staffId ?? "";
  }, [state.error, staffId]);

  return (
    <form action={action} ref={form} className="inline-edit">
      <input type="hidden" name="task_id" value={taskId} />
      <select
        ref={field}
        name="staff_id"
        defaultValue={staffId ?? ""}
        aria-label="Assigned to"
        onChange={() => form.current?.requestSubmit()}
      >
        <option value="">Nobody</option>
        {staff.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </select>
      {state.error && <span className="inline-edit-error">{state.error}</span>}
    </form>
  );
}
