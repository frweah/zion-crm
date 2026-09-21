"use client";

import { useActionState } from "react";
import { setFollowup, type FollowupState } from "./actions";

const initial: FollowupState = { error: null, ok: null };

/** Owner, next action and due date for one authorization, saved in place. */
export function FollowupForm({
  authId,
  owner,
  action: nextAction,
  due,
  staff,
}: {
  authId: string;
  owner: string | null;
  action: string;
  due: string | null;
  staff: { id: string; name: string }[];
}) {
  const [state, formAction, pending] = useActionState(setFollowup, initial);
  return (
    <form action={formAction} className="row2" style={{ gap: 6, alignItems: "center", flexWrap: "wrap" }}>
      <input type="hidden" name="auth_id" value={authId} />
      <select
        id={`owner-${authId}`}
        name="owner"
        defaultValue={owner ?? ""}
        aria-label="Owner"
        style={{ maxWidth: 150 }}
      >
        <option value="">— no owner —</option>
        {staff.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </select>
      <input
        id={`action-${authId}`}
        name="action"
        defaultValue={nextAction}
        placeholder="Next action"
        aria-label="Next action"
        maxLength={500}
        style={{ flex: "1 1 180px", minWidth: 0 }}
      />
      <input
        id={`due-${authId}`}
        name="due"
        type="date"
        defaultValue={due ?? ""}
        aria-label="Due"
        style={{ maxWidth: 150 }}
      />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Save"}
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</span>}
      {state.ok && !pending && <span className="lock">{state.ok}</span>}
    </form>
  );
}
