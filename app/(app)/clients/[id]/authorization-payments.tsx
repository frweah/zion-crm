import { money } from "@/lib/constants";
import type { PaymentRow } from "@/lib/payments";
import { WarrantLink, recordedHow } from "../../billing/warrants/warrant-link";

/**
 * What USOR paid on one authorization: each payment with its warrant, the
 * warrant's date and voucher, and the page image when the stub was read.
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
          <span>{p.warrant_date ?? "no date"}</span>
          <span className="lock">
            warrant <WarrantLink payment={p} />
            {p.voucher && ` · voucher ${p.voucher}`} · {recordedHow(p)}
          </span>
        </div>
      ))}
    </div>
  );
}
