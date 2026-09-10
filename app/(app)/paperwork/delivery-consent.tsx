"use client";

import { useActionState } from "react";
import { setEDeliveryConsent } from "../admin/contractors/actions";
import type { ContractorState } from "../admin/contractors/actions";

const initial: ContractorState = { error: null, ok: null };

/**
 * Consent to receive a 1099 electronically.
 *
 * This is the one thing on a contractor's profile that Admin cannot set,
 * because consent given on somebody else's behalf is not consent. Without it
 * the copy has to be posted, and the database refuses to record an electronic
 * delivery — which is the point: "we emailed it" has to be defensible a year
 * later.
 */
export function DeliveryConsent({ consentedOn }: { consentedOn: string | null }) {
  const [state, action, pending] = useActionState(setEDeliveryConsent, initial);

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3>How your 1099 reaches you</h3>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <p className="sub" style={{ marginTop: 0 }}>
        {consentedOn
          ? `You agreed on ${consentedOn} to receive it electronically.`
          : "Unless you agree otherwise, your 1099 is posted to the address on your profile."}
      </p>

      <form action={action}>
        <label style={{ fontSize: 13, display: "block", marginBottom: 10 }}>
          <input
            type="checkbox"
            name="consent"
            defaultChecked={Boolean(consentedOn)}
            style={{ width: "auto", marginRight: 8 }}
          />
          I agree to receive my 1099 electronically instead of on paper
        </label>
        <p className="lock" style={{ marginTop: 0 }}>
          You can withdraw this at any time by unticking the box, and you may ask for a paper copy
          even after agreeing. If you change email address, tell the administrator — an electronic
          copy sent to an address you no longer read has not reached you.
        </p>
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save"}
        </button>
      </form>
    </div>
  );
}
