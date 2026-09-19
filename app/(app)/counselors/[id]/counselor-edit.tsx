"use client";

import { useActionState, useState } from "react";
import { updateCounselor, moveCounselorOffice, type CounselorState } from "../actions";

const initial: CounselorState = { error: null, ok: null };

function Message({ state }: { state: CounselorState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export type CounselorDetails = {
  id: string;
  name: string;
  agency: string | null;
  office: string | null;
  phone: string | null;
  fax: string | null;
  email: string | null;
  notes: string | null;
};

export function EditCounselorForm({ counselor }: { counselor: CounselorDetails }) {
  const [state, action, pending] = useActionState(updateCounselor, initial);

  return (
    <div className="card">
      <h3>Details</h3>
      <Message state={state} />
      <form action={action}>
        <input type="hidden" name="id" value={counselor.id} />
        <div className="row2">
          <label className="field">
            Name
            <input id="counselor-name" name="name" required defaultValue={counselor.name} />
          </label>
          <label className="field">
            Agency
            <input id="counselor-agency" name="agency" defaultValue={counselor.agency ?? ""} />
          </label>
          <label className="field">
            Email
            <input id="counselor-email" name="email" type="email" defaultValue={counselor.email ?? ""} />
          </label>
        </div>
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Phone
            <input id="counselor-phone" name="phone" defaultValue={counselor.phone ?? ""} />
          </label>
          <label className="field">
            Fax
            <input id="counselor-fax" name="fax" defaultValue={counselor.fax ?? ""} />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Notes
            <input id="counselor-notes" name="notes" defaultValue={counselor.notes ?? ""} />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Save"}
          </button>
        </div>
        <p className="lock" style={{ margin: "8px 0 0" }}>
          Every change is logged, with who made it. To change the office, use Moved office.
        </p>
      </form>
    </div>
  );
}

/**
 * A move is not an edit: it takes a reason, and it says before saving what it
 * does to billing - the billing office follows the office, so every client on
 * the caseload goes with it.
 */
export function MoveOfficeForm({
  counselor,
  offices,
  clients,
}: {
  counselor: CounselorDetails;
  offices: { name: string; billing: string | null }[];
  clients: number;
}) {
  const [state, action, pending] = useActionState(moveCounselorOffice, initial);
  const [to, setTo] = useState("");
  const billingOf = (name: string | null) => offices.find((o) => o.name === name)?.billing ?? null;
  const fromBilling = billingOf(counselor.office);
  const toBilling = to ? billingOf(to) : null;
  const plural = clients === 1 ? "client" : "clients";

  return (
    <div className="card">
      <h3>Moved office</h3>
      <Message state={state} />
      <form action={action}>
        <input type="hidden" name="id" value={counselor.id} />
        <div className="row2">
          <label className="field">
            From
            <input id="move-from" value={`${counselor.office ?? "No office"} · ${fromBilling ?? "no billing office"}`} readOnly disabled />
          </label>
          <label className="field">
            To
            <select id="move-to" name="office" required value={to} onChange={(e) => setTo(e.target.value)}>
              <option value="">— choose —</option>
              {offices
                .filter((o) => o.name !== counselor.office)
                .map((o) => (
                  <option key={o.name} value={o.name}>
                    {o.name} · {o.billing ?? "no billing office"}
                  </option>
                ))}
            </select>
          </label>
        </div>
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" style={{ flex: 2 }}>
            Why
            <input id="move-reason" name="reason" required placeholder="Moved to the Taylorsville office" />
          </label>
          <button className="btn gold" type="submit" disabled={pending || !to}>
            {pending ? "Moving…" : "Move"}
          </button>
        </div>
        <p className="lock" style={{ margin: "8px 0 0" }} aria-live="polite">
          {!to
            ? "Choose the office they moved to. Their clients' billing office follows the office."
            : fromBilling === toBilling
              ? `The billing office stays ${toBilling ?? "unset"}. ${clients} ${plural} on the caseload.`
              : `Billing office changes from ${fromBilling ?? "none"} to ${toBilling ?? "none"} for the ${clients} ${plural} on the caseload.`}
        </p>
      </form>
    </div>
  );
}
