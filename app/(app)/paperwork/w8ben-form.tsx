"use client";

import { useState, useActionState } from "react";
import { signW8BEN, type PaperworkState } from "./actions";

const initial: PaperworkState = { error: null, ok: null };

/**
 * Form W-8BEN, Certificate of Foreign Status.
 *
 * Part II — the treaty claim — is behind a disclosure rather than on the face
 * of the form. For services performed outside the United States there is no
 * US-source income to claim a treaty rate against, so for the people who will
 * use this it is a box that should stay empty. Putting it in front of them
 * invites a wrong answer to a question they did not need to be asked.
 */
export function W8BenForm({ defaultName }: { defaultName: string }) {
  const [state, action, pending] = useActionState(signW8BEN, initial);
  const [ftinNotRequired, setFtinNotRequired] = useState(false);
  const [showTreaty, setShowTreaty] = useState(false);
  const [name, setName] = useState(defaultName);

  return (
    <div className="card">
      <h3>Form W-8BEN — Certificate of Foreign Status</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        This tells us you are not a US person, so no US tax is withheld from what you are paid and
        no 1099 is issued. It stays valid to the end of the third year after you sign it.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <h3 style={{ marginTop: 20 }}>Who you are</h3>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            1 · Full legal name
            <input name="name" value={name} onChange={(e) => setName(e.target.value)} required />
          </label>
          <label className="field">
            2 · Country of citizenship
            <input name="citizenship_country" required />
          </label>
        </div>

        <h3 style={{ marginTop: 20 }}>Where you live</h3>
        <p className="lock" style={{ marginTop: 0 }}>
          Your permanent home address. Not a post office box, and not care of anyone else — the IRS
          rejects both here.
        </p>
        <label className="field">
          3 · Street address
          <input name="residence_street" required />
        </label>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            City or town, state or province, postal code
            <input name="residence_city" required />
          </label>
          <label className="field">
            Country
            <input name="residence_country" required />
          </label>
        </div>

        <h3 style={{ marginTop: 20 }}>Postal address, if different</h3>
        <label className="field">
          4 · Street address
          <input name="mailing_street" />
        </label>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            City or town, state or province, postal code
            <input name="mailing_city" />
          </label>
          <label className="field">
            Country
            <input name="mailing_country" />
          </label>
        </div>

        <h3 style={{ marginTop: 20 }}>Tax numbers</h3>
        <div className="row2">
          <label className="field">
            5 · US taxpayer number, if you have one
            <input name="us_tin" placeholder="Leave blank if you have none" maxLength={11} />
          </label>
          <label className="field">
            6a · Foreign tax identifying number
            <input
              name="foreign_tin"
              maxLength={20}
              disabled={ftinNotRequired}
              placeholder={ftinNotRequired ? "Not required" : "From your own country"}
            />
          </label>
          <label className="field" style={{ maxWidth: 200 }}>
            8 · Date of birth
            <input name="date_of_birth" type="date" />
          </label>
        </div>

        <label style={{ fontSize: 13, display: "block", marginTop: 4 }}>
          <input
            type="checkbox"
            name="ftin_not_required"
            style={{ width: "auto", marginRight: 8 }}
            checked={ftinNotRequired}
            onChange={(e) => setFtinNotRequired(e.target.checked)}
          />
          6b · My country does not issue tax identifying numbers, or I am not legally required to
          have one
        </label>

        <label className="field" style={{ marginTop: 14 }}>
          7 · Reference number, if you were asked for one
          <input name="reference" />
        </label>

        <p className="lock" style={{ marginTop: 14 }}>
          Your tax numbers and date of birth are encrypted when you sign, and only the
          administrator can open the completed form.
        </p>

        <div style={{ marginTop: 20 }}>
          <button className="btn ghost" type="button" onClick={() => setShowTreaty(!showTreaty)}>
            {showTreaty ? "Hide" : "Claiming a tax treaty benefit?"}
          </button>
          {showTreaty && (
            <div style={{ marginTop: 12 }}>
              <div className="alert">
                Only relevant if you are claiming a reduced rate of US withholding under a treaty
                between your country and the United States. Work performed entirely outside the
                United States is not US-source income, so there is usually nothing to claim here.
                Leave it blank if you are unsure.
              </div>
              <label className="field">
                9 · Country whose treaty you are claiming under
                <input name="treaty_country" />
              </label>
            </div>
          )}
        </div>

        <h3 style={{ marginTop: 24 }}>Sign</h3>
        <div className="alert">
          By signing you certify, under penalties of perjury, that you are the beneficial owner of
          the income this relates to, that you are not a US person, and that the details above are
          true and correct. You also undertake to give us a new form within 30 days if any of it
          stops being true.
        </div>

        <label style={{ fontSize: 13, display: "block", marginBottom: 12 }}>
          <input type="checkbox" name="certify" style={{ width: "auto", marginRight: 8 }} required />
          I have read the certification above and it is true
        </label>

        <label style={{ fontSize: 13, display: "block", marginBottom: 14 }}>
          <input
            type="checkbox"
            name="signing_for_another"
            style={{ width: "auto", marginRight: 8 }}
          />
          I am signing for the person named on line 1 rather than for myself
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
