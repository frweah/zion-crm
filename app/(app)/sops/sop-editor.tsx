"use client";

import { useActionState } from "react";
import { createSop, updateSop, type SopState } from "./actions";
import { ROLE_NAMES, ROLE_LABEL, type Role } from "@/lib/roles";

const initial: SopState = { error: null, ok: null };

export type Sop = {
  id: string;
  title: string;
  body: string;
  roles: string[];
  screen: string | null;
};

function RoleBoxes({ selected }: { selected: string[] }) {
  return (
    <div className="row2" style={{ marginTop: 10, fontSize: 12, alignItems: "center" }}>
      <span style={{ color: "var(--muted)" }}>Visible to:</span>
      {ROLE_NAMES.map((r: Role) => (
        <label key={r}>
          <input
            type="checkbox"
            name="roles"
            value={r}
            style={{ width: "auto", marginRight: 4 }}
            defaultChecked={selected.includes(r)}
            disabled={r === "Admin"}
          />
          {ROLE_LABEL[r]}
        </label>
      ))}
    </div>
  );
}

export function SopEditor({ sop }: { sop: Sop }) {
  const [state, action, pending] = useActionState(updateSop, initial);

  return (
    <>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action} key={sop.id}>
        <input type="hidden" name="sop_id" value={sop.id} />
        <input
          name="title"
          defaultValue={sop.title}
          style={{ fontWeight: 600, marginBottom: 8 }}
        />
        <textarea name="body" rows={12} defaultValue={sop.body} />
        <RoleBoxes selected={sop.roles} />
        <button className="btn" type="submit" disabled={pending} style={{ marginTop: 12 }}>
          {pending ? "Saving…" : "Save procedure"}
        </button>
      </form>
    </>
  );
}

export function NewSop() {
  const [state, action, pending] = useActionState(createSop, initial);

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3>New procedure</h3>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <input name="title" placeholder="Title" required />
        <textarea
          name="body"
          rows={4}
          placeholder="Steps, in plain language"
          style={{ marginTop: 8 }}
          required
        />
        <RoleBoxes selected={["Admin", "Job Search", "Reports", "Billing"]} />
        <button className="btn gold" type="submit" disabled={pending} style={{ marginTop: 12 }}>
          {pending ? "Adding…" : "Add procedure"}
        </button>
      </form>
    </div>
  );
}
