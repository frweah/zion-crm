/**
 * The billing board's shape, and the roll-up from authorizations to clients.
 *
 * Separate from `lib/billing-board.ts` because that one is `server-only` - it
 * holds the read - and the grid that draws these rows is a client component.
 * A client component importing a server-only module fails the build with
 * "You're importing a component that needs server-only", which is how this
 * file came to exist. Nothing here touches the database; it is types and
 * arithmetic.
 */

/** The six groups, most pressing first. The rank comes from the database. */
export const BOARD_GROUPS = [
  "Needs invoice",
  "Too late to bill",
  "Waiting on payment",
  "Waiting for service",
  "Paid",
  "Closed",
] as const;

export type BoardGroup = (typeof BOARD_GROUPS)[number];

/** Which groups open closed: the two that need nothing from anybody. */
export const COLLAPSED_GROUPS: readonly BoardGroup[] = ["Paid", "Closed"];

export type BoardAuthorization = {
  auth_id: string;
  client_id: string;
  client_name: string;
  office: string | null;
  counselor_name: string | null;
  number: string;
  service_type: string;
  period: string | null;
  status: string;
  invoice_number: string | null;
  invoice_count: number;
  authorized: number;
  invoiced: number;
  paid: number;
  outstanding: number;
  amount: number | null;
  basis: string | null;
  /** The day the authorization arrived from USOR. Not the day money arrived. */
  received_on: string | null;
  submitted_on: string | null;
  /** The day the money arrived. Typed into on the board; see record_payment. */
  paid_on: string | null;
  delivered_on: string | null;
  bill_by: string | null;
  has_invoice: boolean;
  blocked: boolean;
  attention: string | null;
  urgency: number;
  grp: BoardGroup;
  grp_rank: number;
};

export type BoardClient = {
  client_id: string;
  client_name: string;
  office: string | null;
  counselor_name: string | null;
  /** The group the client sits in: its most pressing authorization's. */
  grp: BoardGroup;
  grp_rank: number;
  authorized: number;
  billed: number;
  outstanding: number;
  /** The latest of each across the client's authorizations. */
  submitted_on: string | null;
  paid_on: string | null;
  /** The most urgent authorization's sentence, which is the client's next step. */
  attention: string | null;
  urgency: number;
  bill_by: string | null;
  rows: BoardAuthorization[];
};

/** Later of two days, either of which may be missing. */
const later = (a: string | null, b: string | null) => (!a ? b : !b ? a : a > b ? a : b);

/** Earlier of two days, for the bill-by a group sorts on. */
const earlier = (a: string | null, b: string | null) => (!a ? b : !b ? a : a < b ? a : b);

/**
 * One row per client, in the group of its most pressing authorization.
 *
 * The money adds up across every authorization the client has, including the
 * settled ones: "what does this client owe us" is a question about the client
 * and not about the rows that happen to be open, and the whole point of the
 * board is that the figure is on screen instead of added up by eye.
 */
export function byClient(rows: BoardAuthorization[]): BoardClient[] {
  const out = new Map<string, BoardClient>();
  for (const r of rows) {
    const c = out.get(r.client_id);
    if (!c) {
      out.set(r.client_id, {
        client_id: r.client_id,
        client_name: r.client_name,
        office: r.office,
        counselor_name: r.counselor_name,
        grp: r.grp,
        grp_rank: r.grp_rank,
        authorized: r.authorized,
        billed: r.invoiced,
        outstanding: r.outstanding,
        submitted_on: r.submitted_on,
        paid_on: r.paid_on,
        attention: r.attention,
        urgency: r.urgency,
        bill_by: r.bill_by,
        rows: [r],
      });
      continue;
    }
    c.rows.push(r);
    c.authorized += r.authorized;
    c.billed += r.invoiced;
    c.outstanding += r.outstanding;
    c.submitted_on = later(c.submitted_on, r.submitted_on);
    c.paid_on = later(c.paid_on, r.paid_on);
    c.bill_by = earlier(c.bill_by, r.bill_by);
    // The client sits where its most pressing authorization sits.
    if (r.grp_rank < c.grp_rank) {
      c.grp = r.grp;
      c.grp_rank = r.grp_rank;
    }
    // And says what that one says. Urgency is lowest-is-worst, as everywhere.
    if (r.urgency < c.urgency) {
      c.attention = r.attention;
      c.urgency = r.urgency;
    }
    c.office = c.office ?? r.office;
    c.counselor_name = c.counselor_name ?? r.counselor_name;
  }
  return [...out.values()].sort(
    (a, b) =>
      a.grp_rank - b.grp_rank ||
      (a.bill_by ?? "9999").localeCompare(b.bill_by ?? "9999") ||
      a.client_name.localeCompare(b.client_name),
  );
}

/** What a group's strip says: how many, and what they come to. */
export function groupTotals(clients: BoardClient[]) {
  return {
    clients: clients.length,
    authorizations: clients.reduce((n, c) => n + c.rows.length, 0),
    authorized: clients.reduce((n, c) => n + c.authorized, 0),
    billed: clients.reduce((n, c) => n + c.billed, 0),
    outstanding: clients.reduce((n, c) => n + c.outstanding, 0),
  };
}
