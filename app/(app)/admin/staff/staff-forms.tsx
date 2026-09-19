"use client";

import { useActionState, useState } from "react";
import { inviteStaff, resendInvite, setStaffActive, type StaffState } from "./actions";
import { ROLE_NAMES, ROLE_LABEL } from "@/lib/roles";

const initial: StaffState = { error: null, ok: null };

function Message({ state }: { state: StaffState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export function InviteForm() {
  const [state, action, pending] = useActionState(inviteStaff, initial);
  const [engagement, setEngagement] = useState("Employee");

  return (
    <>
      <Message state={state} />
      <form action={action}>
        <label className="field">
          Name
          <input name="name" required />
        </label>
        <label className="field">
          Work email
          <input name="email" type="email" required />
        </label>
        <label className="field">
          Role
          <select name="role" defaultValue="Job Search">
            {ROLE_NAMES.map((r) => (
              <option key={r} value={r}>
                {ROLE_LABEL[r]}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          Engaged as
          <select id="invite-engagement" name="employment_type" value={engagement} onChange={(e) => setEngagement(e.target.value)}>
            <option value="Employee">Employee - W-4 and I-9</option>
            <option value="Contractor">Contractor - W-9 or W-8BEN</option>
          </select>
        </label>
        {engagement === "Employee" && (
          <label className="field">
            Start date
            <input id="invite-start" name="started_on" type="date" />
          </label>
        )}
        <button className="btn" type="submit" disabled={pending} style={{ width: "100%" }}>
          {pending ? "Sending…" : "Add and send invite"}
        </button>
      </form>
      <p className="sub" style={{ fontSize: "var(--text-sm)", marginTop: 10, marginBottom: 0 }}>
        They receive an email asking them to complete onboarding, choose their own password, and
        are taken through it on first sign-in: personal details, identity documents,
        certifications, tax form, the data-handling policy, and payment. The rest of the CRM
        opens when they finish.
      </p>
    </>
  );
}

export function StaffRowActions({
  staffId,
  email,
  active,
  accepted,
  invited,
}: {
  staffId: string;
  email: string;
  active: boolean;
  accepted: boolean;
  invited: boolean;
}) {
  const [resendState, resendAction, resending] = useActionState(resendInvite, initial);
  const [activeState, activeAction, saving] = useActionState(setStaffActive, initial);

  const message = resendState.error ?? activeState.error ?? resendState.ok ?? activeState.ok;
  const isError = Boolean(resendState.error ?? activeState.error);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6, alignItems: "flex-end" }}>
      <div style={{ display: "flex", gap: 6 }}>
        {active && !accepted && (
          <form action={resendAction}>
            <input type="hidden" name="email" value={email} />
            <button className="btn ghost" type="submit" disabled={resending}>
              {resending ? "Sending…" : invited ? "Resend invite" : "Send invite"}
            </button>
          </form>
        )}
        <form action={activeAction}>
          <input type="hidden" name="staffId" value={staffId} />
          <input type="hidden" name="active" value={active ? "false" : "true"} />
          <button className="btn ghost" type="submit" disabled={saving}>
            {saving ? "Saving…" : active ? "Deactivate" : "Reactivate"}
          </button>
        </form>
      </div>
      {message && (
        <div style={{ fontSize: "var(--text-sm)", color: isError ? "var(--bad)" : "var(--ok)", maxWidth: 320 }}>
          {message}
        </div>
      )}
    </div>
  );
}
