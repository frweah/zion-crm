"use client";

import Link from "next/link";
import { useActionState } from "react";
import { setTaskStatus, type TaskState } from "../tasks/actions";
import { TaskDue, TaskWho } from "../task-inline";

const initial: TaskState = { error: null, ok: null };

export function DashboardTask({
  id,
  title,
  due,
  clientId,
  overdue,
  assignedStaffId,
  staff,
}: {
  id: string;
  title: string;
  due: string | null;
  clientId: string | null;
  overdue: boolean;
  assignedStaffId: string | null;
  /** Empty for somebody who cannot reassign, which hides the control. */
  staff: { id: string; name: string }[];
}) {
  const [state, action, pending] = useActionState(setTaskStatus, initial);

  return (
    <>
      <div className="taskrow">
        <form action={action}>
          <input type="hidden" name="task_id" value={id} />
          <input type="hidden" name="open" value="true" />
          <button
            className="btn ghost"
            type="submit"
            disabled={pending}
            style={{ padding: "1px 9px", lineHeight: 1.4 }}
            aria-label="Mark done"
          >
            ○
          </button>
        </form>

        <span style={{ flex: 1 }}>
          {clientId ? (
            <Link href={`/clients/${clientId}`} style={{ color: "inherit" }}>
              {title}
            </Link>
          ) : (
            title
          )}
        </span>

        {/* The same two controls as every other task list (Rei, Oct 2026):
            the date and who has it, changed here rather than on a trip to
            the task and back. */}
        <TaskDue taskId={id} due={due} overdue={overdue} />
        {staff.length > 0 && <TaskWho taskId={id} staffId={assignedStaffId} staff={staff} />}
      </div>
      {state.error && (
        <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)", paddingBottom: 6 }}>{state.error}</div>
      )}
    </>
  );
}
