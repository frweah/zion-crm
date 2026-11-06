"use client";

import Link from "next/link";
import { TaskActions } from "../tasks/task-actions";
import { TaskDue, TaskWho } from "../task-inline";

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
  return (
    <>
      <div className="taskrow">
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
        {/* Named rather than drawn. This was a "○" with "Mark done" read out
            to a screen reader and nothing at all to anybody else, which is a
            button that does not say what it does. */}
        <TaskActions taskId={id} compact />
      </div>
    </>
  );
}
