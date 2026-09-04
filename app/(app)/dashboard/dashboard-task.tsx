"use client";

import Link from "next/link";
import { useActionState } from "react";
import { setTaskStatus, type TaskState } from "../tasks/actions";

const initial: TaskState = { error: null, ok: null };

export function DashboardTask({
  id,
  title,
  due,
  clientId,
  overdue,
}: {
  id: string;
  title: string;
  due: string | null;
  clientId: string | null;
  overdue: boolean;
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

        <span className={"chip " + (overdue ? "bad" : "")}>{due ?? "no date"}</span>
      </div>
      {state.error && (
        <div style={{ color: "var(--bad)", fontSize: 12, paddingBottom: 6 }}>{state.error}</div>
      )}
    </>
  );
}
