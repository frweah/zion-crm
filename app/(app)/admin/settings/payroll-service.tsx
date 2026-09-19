"use client";

import { useActionState } from "react";
import { savePayrollService, type PayrollState } from "./payroll-actions";

const initial: PayrollState = { error: null, ok: null };

/**
 * Who runs payroll. New staff are told, during onboarding, to give their bank
 * details to this service themselves; the CRM never holds them. The payer of
 * record they see is the legal name above.
 */
export function PayrollService({ current }: { current: string }) {
  const [state, action, pending] = useActionState(savePayrollService, initial);
  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3>Payroll service</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        Named to new staff in the last onboarding step, where they confirm how they are paid. Their
        bank details go to this service directly, never to the CRM. The payer of record they see is
        the legal name above.
      </p>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      <form action={action} className="row2" style={{ alignItems: "flex-end" }}>
        <label className="field" style={{ flex: 2 }}>
          Service
          <input id="payroll-service" name="payroll_service" defaultValue={current} placeholder="Gusto, ADP, Paychex…" />
        </label>
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save"}
        </button>
      </form>
    </div>
  );
}
