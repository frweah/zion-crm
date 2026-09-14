import type { PaymentRow } from "@/lib/payments";

/** A payment's warrant number, opening the page image when one was kept. */
export function WarrantLink({ payment }: { payment: Pick<PaymentRow, "warrant_no" | "page_id"> }) {
  if (!payment.warrant_no) return <span className="lock">no warrant number</span>;
  if (!payment.page_id) return <span>{payment.warrant_no}</span>;
  return (
    <a
      href={`/billing/warrants/image/${payment.page_id}`}
      target="_blank"
      rel="noopener"
      title="Open the warrant page image"
      style={{ color: "var(--teal)" }}
    >
      {payment.warrant_no} · page image
    </a>
  );
}

/** Where a payment came from, in words. */
export function recordedHow(p: Pick<PaymentRow, "source" | "recorded_by_name">): string {
  if (p.source === "Warrant") return "Read from the warrant";
  if (p.source === "Workbook") return "Workbook import";
  return `By hand${p.recorded_by_name ? ` · ${p.recorded_by_name}` : ""}`;
}
