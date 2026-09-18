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
  // The warrant lines come with their payment, through the line's link to it:
  // one wait on the database instead of two in a row. Somebody who may not see
  // warrants gets none, exactly as when they were a query of their own.
  let payments = supabase
    .from("payments")
    .select("id, auth_id, invoice_id, amount, warrant_no, warrant_date, voucher, source, recorded_by_name, warrant_lines!warrant_lines_payment_id_fkey(page_id)")
    .order("warrant_date", { ascending: false, nullsFirst: false });
  if (authIds) payments = payments.in("auth_id", authIds.length ? authIds : [NONE]);
  const { data } = (await payments) as unknown as {
    data:
      | {
          id: string;
          auth_id: string;
          invoice_id: string | null;
          amount: number;
          warrant_no: string | null;
          warrant_date: string | null;
          voucher: string | null;
          source: string;
          recorded_by_name: string | null;
          warrant_lines: { page_id: string }[] | null;
        }[]
      | null;
  };
  const rows = data ?? [];
  if (rows.length === 0) return [];

  const pageByPayment = new Map<string, string>();
  for (const p of rows) {
    const page = (p.warrant_lines ?? [])[0]?.page_id;
    if (page) pageByPayment.set(p.id, page);
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
