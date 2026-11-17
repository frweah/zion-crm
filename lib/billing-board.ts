import "server-only";
import type { createClient } from "@/lib/supabase/server";
import type { BoardAuthorization, BoardGroup } from "@/lib/billing-board-shape";

type Supabase = Awaited<ReturnType<typeof createClient>>;

/**
 * The billing board's read.
 *
 * One source for two screens: Billing › Authorizations shows every client,
 * the client dashboard's card shows one, and both read `billing_board`. The
 * brief asked for one component rather than two that drift, and the way to
 * make that true is one reader rather than two queries that agree today.
 *
 * The shape and the roll-up are in `lib/billing-board-shape.ts`, which the
 * grid can import; this file cannot be imported by a client component.
 *
 * No warrant and no voucher. The function does not return them and nothing
 * here asks for them - `scripts/check-warrants-stay.mjs` holds that, and the
 * columns are closed in the database anyway since 0360.
 */
export async function readBoard(
  supabase: Supabase,
  clientId?: string,
): Promise<BoardAuthorization[]> {
  const { data } = await supabase.rpc("billing_board", {
    p_today: null,
    p_client: clientId ?? null,
  });
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    auth_id: String(r.auth_id),
    client_id: String(r.client_id),
    client_name: String(r.client_name ?? ""),
    office: (r.office as string | null) ?? null,
    counselor_name: (r.counselor_name as string | null) ?? null,
    number: String(r.number ?? ""),
    service_type: String(r.service_type ?? ""),
    period: (r.period as string | null) ?? null,
    status: String(r.status ?? ""),
    invoice_number: (r.invoice_number as string | null) ?? null,
    invoice_count: Number(r.invoice_count ?? 0),
    authorized: Number(r.authorized ?? 0),
    invoiced: Number(r.invoiced ?? 0),
    paid: Number(r.paid ?? 0),
    outstanding: Number(r.outstanding ?? 0),
    amount: r.amount === null || r.amount === undefined ? null : Number(r.amount),
    basis: (r.basis as string | null) ?? null,
    received_on: (r.received_on as string | null) ?? null,
    submitted_on: (r.submitted_on as string | null) ?? null,
    paid_on: (r.paid_on as string | null) ?? null,
    delivered_on: (r.delivered_on as string | null) ?? null,
    bill_by: (r.bill_by as string | null) ?? null,
    has_invoice: Boolean(r.has_invoice),
    blocked: Boolean(r.blocked),
    attention: (r.attention as string | null) ?? null,
    urgency: Number(r.urgency ?? 99),
    grp: String(r.grp) as BoardGroup,
    grp_rank: Number(r.grp_rank ?? 9),
  }));
}
