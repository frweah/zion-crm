"use client";

import { useActionState } from "react";
import { saveEmployerDetails, type PaperworkState } from "./actions";

const initial: PaperworkState = { error: null, ok: null };

/**
 * The employer block that goes onto every W-4.
 *
 * The EIN is never sent to the browser — the card shows only whether one is on
 * file, and typing a new one replaces it. There is nothing to gain from
 * displaying it back, and a number on a screen is a number in a screenshot.
 */
export function EmployerDetails({
  legalName,
  address,
  hasEin,
}: {
  legalName: string;
  address: string;
  hasEin: boolean;
}) {
  const [state, action, pending] = useActionState(saveEmployerDetails, initial);

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3>Employer details for W-4s</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        These fill the bottom block of every W-4 an employee signs. Until they are set, a signed
        W-4 is stored with that block empty.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <label className="field">
          Legal name of the practice
          <input name="employer_legal_name" defaultValue={legalName} />
        </label>
        <label className="field">
          Address
          <input name="employer_address" defaultValue={address} />
        </label>
        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field" style={{ flex: 2 }}>
            Employer identification number
            <input
              name="employer_ein"
              inputMode="numeric"
              autoComplete="off"
              placeholder={hasEin ? "On file — type a new one to replace it" : "00-0000000"}
            />
            <span className="lock">
              {hasEin
                ? "An EIN is on file. Leave this blank to keep it."
                : "No EIN on file yet."}
            </span>
          </label>
          <button className="btn" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Save"}
          </button>
        </div>
      </form>
    </div>
  );
}
