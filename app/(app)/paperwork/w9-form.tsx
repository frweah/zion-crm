"use client";

import { useState, useActionState } from "react";
import { signW9, type PaperworkState } from "./actions";
import { W9_CLASSIFICATIONS } from "@/lib/irs-forms-shared";

const initial: PaperworkState = { error: null, ok: null };

/**
 * Form W-9, Request for Taxpayer Identification Number and Certification.
 *
 * Line 4's exemption codes and line 7's account numbers are left off. Both are
 * for entities and for payer-side bookkeeping; an individual contractor has
 * nothing to put in either, and an empty box someone feels obliged to fill is
 * how a wrong code ends up on a filed form. Line 3b appears only when the
 * classification chosen actually makes it apply.
 */
export function W9Form({ defaultName }: { defaultName: string }) {
  const [state, action, pending] = useActionState(signW9, initial);
  const [name, setName] = useState(defaultName);
  const [classification, setClassification] = useState<string>("Individual/sole proprietor");
  const [llcClass, setLlcClass] = useState("");
  const [tinType, setTinType] = useState("SSN");

  // Line 3b is for partnerships, trusts and estates, and for an LLC taxed as a
  // partnership. The form says so; showing it to anyone else is noise.
  const showForeignPartners =
    classification === "Partnership" ||
    classification === "Trust/estate" ||
    (classification === "LLC" && llcClass === "P");

  return (
    <div className="card">
      <h3>Form W-9 — Taxpayer Identification Number and Certification</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        This gives us the taxpayer number to report your payments under, and certifies that you are
        a US person so nothing is withheld. It does not expire — you complete a new one only if
        something on it changes.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <h3 style={{ marginTop: 20 }}>Who you are</h3>
        <label className="field">
          1 · Name, as shown on your income tax return
          <input name="name" value={name} onChange={(e) => setName(e.target.value)} required />
        </label>
        <label className="field">
          2 · Business or trade name, if different
          <input name="business_name" placeholder="Leave blank if you have none" />
        </label>

        <label className="field">
          3a · Federal tax classification
          <select
            name="classification"
            value={classification}
            onChange={(e) => setClassification(e.target.value)}
            required
          >
            {W9_CLASSIFICATIONS.map((c) => (
              <option key={c} value={c}>
                {c === "LLC" ? "Limited liability company" : c}
              </option>
            ))}
          </select>
        </label>

        {classification === "LLC" && (
          <label className="field">
            How the LLC is taxed
            <select
              name="llc_tax_classification"
              value={llcClass}
              onChange={(e) => setLlcClass(e.target.value)}
              required
            >
              <option value="">Choose…</option>
              <option value="C">C — taxed as a C corporation</option>
              <option value="S">S — taxed as an S corporation</option>
              <option value="P">P — taxed as a partnership</option>
            </select>
            <span className="lock">
              A single-member LLC that is disregarded does not belong here. Choose the
              classification of its owner on line 3a instead.
            </span>
          </label>
        )}

        {classification === "Other" && (
          <label className="field">
            What the classification is
            <input name="other_classification" required />
          </label>
        )}

        {showForeignPartners && (
          <label style={{ fontSize: 13, display: "block", marginBottom: 12 }}>
            <input
              type="checkbox"
              name="foreign_partners"
              style={{ width: "auto", marginRight: 8 }}
            />
            3b · This entity has foreign partners, owners or beneficiaries, and is giving this form
            to a partnership, trust or estate it holds an ownership interest in
          </label>
        )}

        <h3 style={{ marginTop: 20 }}>Where you are</h3>
        <label className="field">
          5 · Street address, and apartment or suite
          <input name="street" required />
        </label>
        <label className="field">
          6 · City, state and ZIP code
          <input name="city_state_zip" required />
        </label>

        <h3 style={{ marginTop: 20 }}>Your taxpayer number</h3>
        <div className="row2">
          <label className="field">
            Which number
            <select name="tin_type" value={tinType} onChange={(e) => setTinType(e.target.value)}>
              <option value="SSN">Social security number</option>
              <option value="EIN">Employer identification number</option>
            </select>
          </label>
          <label className="field" style={{ flex: 2 }}>
            {tinType === "SSN" ? "Social security number" : "Employer identification number"}
            <input
              name="tin"
              required
              inputMode="numeric"
              autoComplete="off"
              placeholder={tinType === "SSN" ? "000-00-0000" : "00-0000000"}
            />
          </label>
        </div>
        <p className="lock" style={{ marginTop: 0 }}>
          The number has to match the name on line 1, or payments become subject to backup
          withholding. It is encrypted the moment you sign, and only the administrator can open the
          completed form. Nothing anywhere else in this system shows more than the last four
          digits.
        </p>

        <h3 style={{ marginTop: 24 }}>Sign</h3>
        <div className="alert">
          By signing you certify, under penalties of perjury, that the number above is your correct
          taxpayer identification number, that you are not subject to backup withholding, and that
          you are a US citizen or other US person.
        </div>
        <p className="lock" style={{ marginTop: 0 }}>
          If the IRS has told you that you are currently subject to backup withholding for
          unreported interest or dividends, do not sign here. Tell the administrator instead: that
          case requires the second item to be struck out, which can only be done on paper.
        </p>

        <label style={{ fontSize: 13, display: "block", marginBottom: 12 }}>
          <input type="checkbox" name="certify" style={{ width: "auto", marginRight: 8 }} required />
          I have read the certification above and it is true
        </label>

        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field" style={{ flex: 2 }}>
            Type your full name to sign
            <input name="signer_name" required placeholder={name} />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Signing…" : "Sign and file"}
          </button>
        </div>
        <p className="lock" style={{ margin: "10px 0 0" }}>
          Signing records your name, the date and time, and the address you signed from. The form
          cannot be changed afterwards — if something needs correcting you complete a new one,
          which replaces this.
        </p>
      </form>
    </div>
  );
}
