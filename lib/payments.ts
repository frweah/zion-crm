import "server-only";
import type { createClient } from "@/lib/supabase/server";

type Supabase = Awaited<ReturnType<typeof createClient>>;

export type PaymentRow = {
  id: string;
  auth_id: string;
  invoice_id: string | null;
  amount: number;
  warrant_no: string;
  warrant_date: string | null;
  voucher: string;
  source: string;
  recorded_by_name: string;
  /** The warrant page this payment was read from, when a page was kept and the reader may see it. */
  page_id: string | null;
};

const NONE = "00000000-0000-0000-0000-000000000000";

/**
 * Payments on record - the workbook's, those read from warrant stubs, and
 * invoices marked paid by hand - newest warrant first, each with the warrant
 * page it came from. All of them, or those on the authorizations given.
 *
 * The page comes through warrant_lines, which only Admin and Billing may read;
 * anyone else gets the payment without the page.
 */
export async function readPayments(supabase: Supabase, authIds?: string[]): Promise<PaymentRow[]> {
  let payments = supabase
    .from("payments")
    .select("id, auth_id, invoice_id, amount, warrant_no, warrant_date, voucher, source, recorded_by_name")
    .order("warrant_date", { ascending: false, nullsFirst: false });
  if (authIds) payments = payments.in("auth_id", authIds.length ? authIds : [NONE]);
  const { data } = await payments;
  const rows = data ?? [];
  if (rows.length === 0) return [];

  let lines = supabase.from("warrant_lines").select("payment_id, page_id").not("payment_id", "is", null);
  if (authIds) lines = lines.in("payment_id", rows.map((p) => p.id));
  const { data: lineRows } = await lines;
  const pageByPayment = new Map<string, string>();
  for (const l of lineRows ?? []) {
    if (l.payment_id && !pageByPayment.has(l.payment_id)) pageByPayment.set(l.payment_id, l.page_id);
  }

  return rows.map((p) => ({
    id: p.id,
    auth_id: p.auth_id,
    invoice_id: p.invoice_id,
    amount: Number(p.amount),
    warrant_no: p.warrant_no ?? "",
    warrant_date: p.warrant_date,
    voucher: p.voucher ?? "",
    source: p.source,
    recorded_by_name: p.recorded_by_name ?? "",
    page_id: pageByPayment.get(p.id) ?? null,
  }));
}
