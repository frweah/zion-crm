"use client";

import { useActionState, useState } from "react";
import {
  savePersonalDetails,
  uploadIdentityDocument,
  submitCredential,
  confirmCertifications,
  signPolicy,
  savePayment,
  type OnboardingState,
} from "./actions";
import { W9Form } from "../w9-form";
import { W8BenForm } from "../w8ben-form";

const initial: OnboardingState = { error: null, ok: null };

function Message({ state }: { state: OnboardingState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export type Personal = {
  legal_name: string;
  address_line1: string;
  address_line2: string;
  city: string;
  state: string;
  postal_code: string;
  phone: string;
  date_of_birth: string | null;
  emergency_name: string;
  emergency_relationship: string;
  emergency_phone: string;
};

// ── 1 ───────────────────────────────────────────────────────
export function PersonalForm({ personal, today }: { personal: Personal; today: string }) {
  const [state, action, pending] = useActionState(savePersonalDetails, initial);
  return (
    <form action={action}>
      <Message state={state} />
      <div className="row2">
        <label className="field" style={{ flex: 2 }}>
          Legal name
          <input id="ob-legal-name" name="legal_name" required defaultValue={personal.legal_name} autoComplete="name" />
          <span className="lock">As on your ID and tax form - it can differ from the name colleagues use.</span>
        </label>
        <label className="field">
          Date of birth
          <input id="ob-dob" name="date_of_birth" type="date" required max={today} defaultValue={personal.date_of_birth ?? ""} autoComplete="bday" />
        </label>
        <label className="field">
          Phone
          <input id="ob-phone" name="phone" type="tel" required defaultValue={personal.phone} autoComplete="tel" />
        </label>
      </div>
      <div className="row2" style={{ marginTop: 10 }}>
        <label className="field" style={{ flex: 2 }}>
          Street address
          <input id="ob-address1" name="address_line1" required defaultValue={personal.address_line1} autoComplete="address-line1" />
        </label>
        <label className="field">
          Apartment or unit
          <input id="ob-address2" name="address_line2" defaultValue={personal.address_line2} autoComplete="address-line2" />
        </label>
      </div>
      <div className="row2" style={{ marginTop: 10 }}>
        <label className="field">
          City
          <input id="ob-city" name="city" required defaultValue={personal.city} autoComplete="address-level2" />
        </label>
        <label className="field" style={{ maxWidth: 110 }}>
          State
          <input id="ob-state" name="state" required maxLength={2} defaultValue={personal.state || "UT"} autoComplete="address-level1" />
        </label>
        <label className="field" style={{ maxWidth: 140 }}>
          ZIP
          <input id="ob-zip" name="postal_code" required defaultValue={personal.postal_code} autoComplete="postal-code" />
        </label>
      </div>
      <h4 style={{ margin: "16px 0 6px" }}>Emergency contact</h4>
      <div className="row2">
        <label className="field">
          Name
          <input id="ob-em-name" name="emergency_name" required defaultValue={personal.emergency_name} />
        </label>
        <label className="field">
          Relationship
          <input id="ob-em-rel" name="emergency_relationship" defaultValue={personal.emergency_relationship} placeholder="Partner, parent, friend" />
        </label>
        <label className="field">
          Phone
          <input id="ob-em-phone" name="emergency_phone" type="tel" required defaultValue={personal.emergency_phone} />
        </label>
      </div>
      <div className="row2" style={{ marginTop: 12, alignItems: "center" }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save and continue"}
        </button>
        <span className="lock">Seen by you and the administrator only.</span>
      </div>
    </form>
  );
}

// ── 2 ───────────────────────────────────────────────────────
export function IdentityUpload({ employee }: { employee: boolean }) {
  const [state, action, pending] = useActionState(uploadIdentityDocument, initial);
  return (
    <form action={action} style={{ marginTop: 12 }}>
      <Message state={state} />
      <div className="row2" style={{ alignItems: "flex-end" }}>
        <label className="field">
          Which document
          <input
            id="ob-id-what"
            name="what"
            required
            placeholder={employee ? "US passport, or driver's licence + Social Security card" : "Driver's licence or passport"}
          />
        </label>
        <label className="field">
          Scan or photo
          <input id="ob-id-file" name="file" type="file" required accept="application/pdf,image/*" />
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Uploading…" : "Upload"}
        </button>
      </div>
    </form>
  );
}

// ── 3 ───────────────────────────────────────────────────────
export function CredentialForm({ typeKey, label, expires }: { typeKey: string; label: string; expires: boolean }) {
  const [state, action, pending] = useActionState(submitCredential, initial);
  const [open, setOpen] = useState(false);
  if (!open) {
    return (
      <>
        <button className="btn ghost" type="button" onClick={() => setOpen(true)}>
          Add {label}
        </button>
      </>
    );
  }
  return (
    <form action={action}>
      <Message state={state} />
      <input type="hidden" name="type_key" value={typeKey} />
      <div className="row2" style={{ alignItems: "flex-end" }}>
        <label className="field">
          Card or certificate number
          <input id={`ob-cred-ref-${typeKey}`} name="reference" placeholder={typeKey === "licence" ? "Last four only" : ""} />
        </label>
        <label className="field" style={{ maxWidth: 170 }}>
          Issued
          <input id={`ob-cred-issued-${typeKey}`} name="issued_on" type="date" />
        </label>
        <label className="field" style={{ maxWidth: 170 }}>
          Expires
          <input id={`ob-cred-expires-${typeKey}`} name="expires_on" type="date" required={expires} />
        </label>
        <label className="field">
          Scan or photo of the card
          <input id={`ob-cred-file-${typeKey}`} name="file" type="file" required accept="application/pdf,image/*" />
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Sending…" : "Put forward"}
        </button>
      </div>
    </form>
  );
}

export function ConfirmCertifications() {
  const [state, action, pending] = useActionState(confirmCertifications, initial);
  return (
    <form action={action} style={{ marginTop: 14 }}>
      <Message state={state} />
      <button className="btn gold" type="submit" disabled={pending}>
        {pending ? "Saving…" : "That is everything I hold for now"}
      </button>
    </form>
  );
}

// ── 4: which tax form, when Admin has not said ──────────────
export function TaxFormChooser({ defaultName }: { defaultName: string }) {
  const [which, setWhich] = useState<"" | "W-9" | "W-8BEN">("");
  return (
    <>
      <fieldset className="field" style={{ border: 0, padding: 0, margin: "0 0 12px" }}>
        <legend style={{ marginBottom: 6 }}>For US tax purposes, are you a US citizen or resident?</legend>
        <label style={{ display: "block" }}>
          <input id="ob-tax-us" type="radio" name="tax_person" checked={which === "W-9"} onChange={() => setWhich("W-9")} /> Yes - I
          give a W-9
        </label>
        <label style={{ display: "block" }}>
          <input id="ob-tax-foreign" type="radio" name="tax_person" checked={which === "W-8BEN"} onChange={() => setWhich("W-8BEN")} /> No -
          I give a W-8BEN
        </label>
      </fieldset>
      {which === "W-9" && <W9Form defaultName={defaultName} />}
      {which === "W-8BEN" && <W8BenForm defaultName={defaultName} />}
    </>
  );
}

// ── 5 ───────────────────────────────────────────────────────
export function PolicySignForm({ version, legalName }: { version: number; legalName: string }) {
  const [state, action, pending] = useActionState(signPolicy, initial);
  return (
    <form action={action} style={{ marginTop: 14 }}>
      <Message state={state} />
      <input type="hidden" name="version" value={version} />
      <label style={{ display: "flex", gap: 8, alignItems: "flex-start", margin: "0 0 10px" }}>
        <input id="ob-policy-read" type="checkbox" name="read" required />
        <span>
          I have read this policy. I understand what I may access and what I may not, and I understand that I am
          responsible for what happens under my login.
        </span>
      </label>
      <div className="row2" style={{ alignItems: "flex-end" }}>
        <label className="field">
          Type your legal name to sign
          <input id="ob-policy-signer" name="signer_name" required defaultValue={legalName} autoComplete="name" />
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Signing…" : "Sign"}
        </button>
      </div>
      <p className="lock" style={{ margin: "8px 0 0" }}>
        Typing your name and pressing Sign is your signature. A signed copy, with the date, time and the exact text you
        were shown, goes on your file.
      </p>
    </form>
  );
}

// ── 6 ───────────────────────────────────────────────────────
export function PaymentForm({
  payer,
  payroll,
  current,
}: {
  payer: string;
  payroll: string;
  current: { method: string } | null;
}) {
  const [state, action, pending] = useActionState(savePayment, initial);
  const [method, setMethod] = useState(current?.method ?? "Direct deposit through the payroll service");
  const service = payroll || "the payroll service";
  return (
    <form action={action}>
      <Message state={state} />
      <div className="row2" style={{ margin: "0 0 12px", gap: 24 }}>
        <div>
          <div className="lock">Payer of record</div>
          <b>{payer || <span className="lock">Not set yet - the administrator sets it in Settings.</span>}</b>
        </div>
        <div>
          <div className="lock">Payroll service</div>
          <b>{payroll || <span className="lock">Not named yet</span>}</b>
        </div>
      </div>
      <fieldset style={{ border: 0, padding: 0, margin: "0 0 10px" }}>
        <legend style={{ marginBottom: 6 }}>How would you like to be paid?</legend>
        {["Direct deposit through the payroll service", "Paper check"].map((m) => (
          <label key={m} style={{ display: "block" }}>
            <input
              id={`ob-pay-${m.startsWith("Direct") ? "deposit" : "check"}`}
              type="radio"
              name="method"
              value={m}
              checked={method === m}
              onChange={() => setMethod(m)}
            />{" "}
            {m.startsWith("Direct") ? `Direct deposit, through ${service}` : "Paper check"}
          </label>
        ))}
      </fieldset>
      {method.startsWith("Direct") && (
        <label style={{ display: "flex", gap: 8, alignItems: "flex-start", margin: "0 0 10px" }}>
          <input id="ob-pay-bank" type="checkbox" name="bank_details_with_payroll" />
          <span>
            I have given, or will give, my bank details to {service} myself. I will not type them here, email them, or
            hand them to a colleague.
          </span>
        </label>
      )}
      <button className="btn gold" type="submit" disabled={pending || !payer}>
        {pending ? "Saving…" : "Confirm"}
      </button>
      <p className="lock" style={{ margin: "8px 0 0" }}>
        No account or routing number is ever stored in the CRM. {service.charAt(0).toUpperCase() + service.slice(1)} holds those.
      </p>
    </form>
  );
}
