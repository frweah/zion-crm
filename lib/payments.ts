import "server-only";
import type { createClient } from "@/lib/supabase/server";

type Supabase = Awaited<ReturnType<typeof createClient>>;

export type PaymentRow = {
  id: string;
  auth_id: string;
  amount: number;
  /** The day the money arrived. */
  paid_on: string | null;
  source: string;
  recorded_by_name: string;
};

const NONE = "00000000-0000-0000-0000-000000000000";

/**
 * What was paid on the authorizations given: the amount, the day it arrived,
 * and who recorded it. Newest first.
 *
 * No warrant number, no voucher, no stub page. Warrants moved to Admin on
 * 14 November 2026 and `payments.warrant_no`, `warrant_date` and `voucher` are
 * closed to everybody signed in - including Admin, because a column grant is
 * to the one database role every signed-in person shares. So this reads
 * `payments_for_billing`, which answers with the outcome and nothing else, and
 * the day comes back as `paid_on` because that is what it is: `warrant_date`
 * carries the day the money arrived for a payment recorded by hand, and the
 * day the warrant was issued for one read off a stub, and either way it is the
 * day Billing is owed.
 *
 * The authorizations are not optional. They used to be, and with none the
 * query read every payment the practice has ever taken - a table that grows
 * for as long as the practice runs. Nothing ever called it that way, so the
 * only thing the optional shape did was wait to be called that way one day
 * (stress test, owner 16 Oct 2026).
 */
export async function readPayments(supabase: Supabase, authIds: string[]): Promise<PaymentRow[]> {
  const { data } = await supabase.rpc("payments_for_billing", {
    p_auths: authIds.length ? authIds : [NONE],
  });

  const rows = (data ?? []) as {
    id: string;
    auth_id: string;
    amount: number;
    paid_on: string | null;
    source: string;
    recorded_by_name: string | null;
  }[];

  return rows.map((p) => ({
    id: p.id,
    auth_id: p.auth_id,
    amount: Number(p.amount),
    paid_on: p.paid_on,
    source: p.source,
    recorded_by_name: p.recorded_by_name ?? "",
  }));
}

/**
 * Where a payment came from, in words.
 *
 * It lived beside the warrant link in `billing/warrants/warrant-link.tsx`
 * until warrants moved to Admin. The link went with them; this stayed, because
 * how a payment came to be on record is an outcome Billing may read, and it
 * names no warrant.
 */
export function recordedHow(p: Pick<PaymentRow, "source" | "recorded_by_name">): string {
  if (p.source === "Warrant") return "Read from the warrant";
  if (p.source === "Workbook") return "Workbook import";
  return `By hand${p.recorded_by_name ? ` · ${p.recorded_by_name}` : ""}`;
}
