"use client";

import { useActionState, useState } from "react";
import { recordNumberConsent } from "../../clients/[id]/numbers-actions";
import type { DetailState } from "../../clients/[id]/actions";

const initial: DetailState = { error: null, ok: null };

/**
 * One number, one answer (owner, 9 November 2026).
 *
 * The same action the client's own record uses, because it is the same
 * decision written down in the same place. There is no form here that takes
 * more than one number: the owner asked for them one by one, and a bulk
 * control would make a record of thirty conversations that happened once.
 */
export function RecordConsent({
  clientId,
  phone,
  who,
}: {
  clientId: string;
  phone: string;
  who: string;
}) {
  const [state, action, pending] = useActionState(recordNumberConsent, initial);
  const [open, setOpen] = useState(false);

  if (state.ok) return <span className="chip ok">{state.ok}</span>;

  if (!open) {
    return (
      <button type="button" className="btn ghost" onClick={() => setOpen(true)}>
        Record
      </button>
    );
  }

  return (
    <form action={action}>
      <input type="hidden" name="id" value={clientId} />
      <input type="hidden" name="phone" value={phone} />
      {state.error && <p className="alert bad">{state.error}</p>}
      <div className="row2">
        <label className="field">
          <span>What {who || "they"} said</span>
          <select name="state" defaultValue="Granted">
            <option value="Granted">Granted</option>
            <option value="Declined">Declined</option>
            <option value="Withdrawn">Withdrawn</option>
          </select>
        </label>
        <label className="field">
          <span>How</span>
          <select name="method" defaultValue="Verbal">
            <option value="Verbal">Verbal</option>
            <option value="Intake form">Intake form</option>
            <option value="Text reply">Text reply</option>
            <option value="Written">Written</option>
          </select>
        </label>
        <label className="field" style={{ flex: 2 }}>
          <span>How it was given</span>
          <input name="note" placeholder="On the phone, 9 November" />
        </label>
      </div>
      <button className="btn" disabled={pending}>
        {pending ? "…" : "Record it"}
      </button>
      <button type="button" className="btn ghost" style={{ marginLeft: 6 }} onClick={() => setOpen(false)}>
        Leave it
      </button>
    </form>
  );
}
