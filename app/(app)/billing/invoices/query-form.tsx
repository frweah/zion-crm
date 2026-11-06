"use client";

import { useActionState } from "react";
import { recordInvoiceQuery, type QueryState } from "./actions";

const initial: QueryState = { error: null, ok: null };

/**
 * What came of asking about an invoice.
 *
 * One exchange per note: the day, who was asked, what they said. "This
 * settles it" is the only part that changes anything beyond the record - it
 * takes a short payment off the intake desk's list - so it is a tick rather
 * than a status somebody picks.
 */
export function RecordQuery({ invoiceId, today }: { invoiceId: string; today: string }) {
  const [state, action, saving] = useActionState(recordInvoiceQuery, initial);

  return (
    <form action={action} style={{ marginTop: 10 }}>
      <input type="hidden" name="invoice_id" value={invoiceId} />
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <div className="row2" style={{ gap: 8, alignItems: "flex-end", flexWrap: "wrap" }}>
        <label className="field" style={{ maxWidth: 160 }}>
          Asked on
          <input type="date" name="asked_on" defaultValue={today} max={today} />
        </label>
        <label className="field" style={{ minWidth: 200, flex: 1 }}>
          Who was asked
          <input name="asked_of" placeholder="Downtown billing" required />
        </label>
      </div>

      <label className="field" style={{ marginTop: 8 }}>
        What they said
        <textarea name="said" rows={2} />
      </label>

      <label className="row2" style={{ gap: 8, margin: "8px 0", alignItems: "center" }}>
        <input type="checkbox" name="resolved" />
        <span>This settles it</span>
      </label>

      <button className="btn" type="submit" disabled={saving}>
        {saving ? "Recording…" : "Record it"}
      </button>
    </form>
  );
}
