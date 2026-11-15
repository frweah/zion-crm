import { money } from "@/lib/constants";
import { recordedHow, type PaymentRow } from "@/lib/payments";

/**
 * What USOR paid on one authorization: each payment with the day it arrived
 * and where it came from.
 *
 * The warrant number, the voucher and the stub image were here until warrants
 * moved to Admin (14 November 2026). They are read on Admin → Warrants now,
 * and this screen shows the outcome, which is what Billing needs to chase and
 * to reconcile.
 */
export function AuthorizationPayments({ payments, status }: { payments: PaymentRow[]; status: string }) {
  if (payments.length === 0) {
    return status === "Paid" ? (
      <div className="lock" style={{ marginTop: 8 }}>
        Marked Paid, but no payment is on record for it.
      </div>
    ) : null;
  }

  return (
    <div style={{ marginTop: 8, paddingTop: 8, borderTop: "1px solid var(--line)" }}>
      {payments.map((p) => (
        <div key={p.id} className="row2" style={{ alignItems: "center", gap: 6, fontSize: "var(--text-md)", marginBottom: 4 }}>
          <span className="chip ok">Paid {money(p.amount)}</span>
          <span>{p.paid_on ?? "no date"}</span>
          <span className="lock">{recordedHow(p)}</span>
        </div>
      ))}
    </div>
  );
}
