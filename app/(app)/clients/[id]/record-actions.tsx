"use client";

import { useActionState, useEffect, useState } from "react";
import Link from "next/link";
import { addTask, type DetailState } from "./actions";
import { QuickAdd } from "../../quick-add";
import { today } from "@/lib/constants";

type Option = { id: string; name: string };

const initial: DetailState = { error: null, ok: null };

/**
 * The record's actions, in its header on every tab.
 *
 * Adding a task and sending a report used to be tabs of their own. They are
 * things you do to the record, not places in it, so they sit here beside the
 * name - the same four buttons whichever tab is open.
 */
export function RecordActions({
  clientId,
  tab,
  staff,
  myId,
}: {
  clientId: string;
  tab: string;
  staff: Option[];
  myId: string;
}) {
  return (
    <div className="row2 no-print" style={{ gap: 6, flexWrap: "wrap", justifyContent: "flex-end" }}>
      <Link className="btn ghost" href={`/clients/${clientId}?tab=notes`} style={{ textDecoration: "none" }}>
        Add note
      </Link>
      <AddTask clientId={clientId} staff={staff} myId={myId} />
      <Link
        className="btn ghost"
        href={`/clients/${clientId}?tab=${tab}&report=Weekly`}
        style={{ textDecoration: "none" }}
      >
        Send report
      </Link>
      <QuickAdd clientId={clientId} label="Quick add" />
    </div>
  );
}

function AddTask({ clientId, staff, myId }: { clientId: string; staff: Option[]; myId: string }) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState(addTask, initial);

  useEffect(() => {
    if (!open) return;
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [open]);

  return (
    <>
      <button className="btn ghost" type="button" onClick={() => setOpen(true)}>
        Add task
      </button>
      {open && (
        <div
          onClick={() => setOpen(false)}
          style={{
            position: "fixed",
            inset: 0,
            background: "var(--scrim)",
            zIndex: 40,
            display: "flex",
            alignItems: "flex-start",
            justifyContent: "center",
            padding: "8vh 16px",
          }}
        >
          <div
            className="card"
            role="dialog"
            aria-label="Add a task for this client"
            onClick={(e) => e.stopPropagation()}
            style={{ width: "min(520px, 100%)", textAlign: "left" }}
          >
            <div className="row2" style={{ justifyContent: "space-between" }}>
              <h3 style={{ margin: 0 }}>Add a task</h3>
              <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
                Close
              </button>
            </div>
            {state.error && <div className="alert bad">{state.error}</div>}
            {state.ok && <div className="alert ok">{state.ok}</div>}
            <form action={action} style={{ marginTop: 10 }}>
              <input type="hidden" name="id" value={clientId} />
              <label className="field">
                Task
                <input name="title" placeholder="What needs doing" required autoFocus />
              </label>
              <div className="row2">
                <label className="field" style={{ maxWidth: 190 }}>
                  Due
                  <input name="due" type="date" defaultValue={today()} />
                </label>
                <label className="field">
                  Assign to
                  <select name="assigned_staff_id" defaultValue={myId}>
                    {staff.map((s) => (
                      <option key={s.id} value={s.id}>
                        {s.name}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
              <button className="btn gold" type="submit" disabled={pending}>
                {pending ? "Adding…" : "Add task"}
              </button>
              <p className="lock" style={{ margin: "8px 0 0" }}>
                Open tasks show at the top of Activity; done ones join the feed.
              </p>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
