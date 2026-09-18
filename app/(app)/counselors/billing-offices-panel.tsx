"use client";

import { useActionState } from "react";
import type { BillingOffice, OfficeRow } from "@/lib/billing-offices";
import { updateBillingOffice, setOfficeBilling, type BillingOfficeState } from "./billing-office-actions";

const initial: BillingOfficeState = { error: null, ok: null };

function Message({ state }: { state: BillingOfficeState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

function BillingOfficeForm({ office }: { office: BillingOffice }) {
  const [state, action, pending] = useActionState(updateBillingOffice, initial);
  const id = (k: string) => `bo-${office.id}-${k}`;
  return (
    <details style={{ marginTop: 8 }}>
      <summary style={{ cursor: "pointer" }}>{office.name}</summary>
      <form action={action} style={{ marginTop: 10 }}>
        <Message state={state} />
        <input type="hidden" name="id" value={office.id} />
        <input type="hidden" name="name" value={office.name} />
        <div className="row2">
          <label className="field" htmlFor={id("billing_email")}>
            Billing address - the To
            <input id={id("billing_email")} name="billing_email" type="email" defaultValue={office.billing_email} required />
          </label>
          <label className="field" htmlFor={id("contact_name")}>
            Contact
            <input id={id("contact_name")} name="contact_name" defaultValue={office.contact_name} />
          </label>
          <label className="field" htmlFor={id("contact_title")}>
            Their role
            <input id={id("contact_title")} name="contact_title" defaultValue={office.contact_title} />
          </label>
          <label className="field" htmlFor={id("contact_email")}>
            Their address
            <input id={id("contact_email")} name="contact_email" type="email" defaultValue={office.contact_email} />
          </label>
        </div>
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" htmlFor={id("has_group_address")}>
            <input id={id("has_group_address")} name="has_group_address" type="checkbox" defaultChecked={office.has_group_address} />{" "}
            The billing address is the office&apos;s group address, not a person&apos;s
          </label>
          <label className="field" htmlFor={id("notes")} style={{ flex: 2 }}>
            Notes
            <input id={id("notes")} name="notes" defaultValue={office.notes} />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Save"}
          </button>
        </div>
      </form>
    </details>
  );
}

function OfficeForm({ office, billingOffices }: { office: OfficeRow; billingOffices: BillingOffice[] }) {
  const [state, action, pending] = useActionState(setOfficeBilling, initial);
  const id = (k: string) => `office-${office.name.replace(/\W+/g, "-")}-${k}`;
  return (
    <form action={action} className="row2" style={{ marginTop: 8, alignItems: "flex-end" }}>
      <input type="hidden" name="office" value={office.name} />
      <b style={{ minWidth: 120, alignSelf: "center" }}>{office.name}</b>
      <label className="field" htmlFor={id("bo")}>
        Bills through
        <select id={id("bo")} name="billing_office_id" defaultValue={office.billing_office_id} required>
          {billingOffices.map((b) => (
            <option key={b.id} value={b.id}>
              {b.name}
            </option>
          ))}
        </select>
      </label>
      <label className="field" htmlFor={id("address")} style={{ flex: 2 }}>
        Address
        <input id={id("address")} name="address" defaultValue={office.address} />
      </label>
      <label className="field" htmlFor={id("note")} style={{ flex: 2 }}>
        Note
        <input id={id("note")} name="note" defaultValue={office.note} />
      </label>
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Save"}
      </button>
      {(state.error || state.ok) && (
        <div style={{ flexBasis: "100%" }}>
          <Message state={state} />
        </div>
      )}
    </form>
  );
}

/** Admin only: the billing offices' details, and which office bills where. */
export function BillingOfficesPanel({
  billingOffices,
  offices,
}: {
  billingOffices: BillingOffice[];
  offices: OfficeRow[];
}) {
  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3 style={{ marginTop: 0 }}>Change a billing office</h3>
      <p className="lock" style={{ margin: 0 }}>
        A new contact, or a group address that now exists. Changes apply to every email drafted from here on.
      </p>
      {billingOffices.map((b) => (
        <BillingOfficeForm key={b.id} office={b} />
      ))}

      <h3 style={{ marginTop: 22 }}>Which office bills where</h3>
      <p className="lock" style={{ margin: 0 }}>
        Every counselor, client, authorization and invoice follows its office here. Moving an office moves all of them.
      </p>
      {offices.map((o) => (
        <OfficeForm key={o.name} office={o} billingOffices={billingOffices} />
      ))}
    </div>
  );
}
