import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

/**
 * Billing offices: who USOR's money comes from, and who to chase for it.
 *
 * Each counselor office bills through one CRP billing office (0091). A client
 * inherits theirs from their counselor's office, else their referring office;
 * an authorization or invoice inherits its client's. The database decides that
 * (client_billing_office); this file only reads the answer and says it the same
 * way on every screen.
 */

export type BillingOffice = {
  id: string;
  name: string;
  billing_email: string;
  has_group_address: boolean;
  contact_name: string;
  contact_title: string;
  contact_email: string;
  notes: string;
};

/**
 * A counselor office.
 *
 * billing_office_id is nullable as of 0195: sixteen of the twenty-two offices
 * the USOR roster brought in bill through a CRP nobody has named yet, and that
 * column decides where an authorization packet is emailed - so it is empty
 * rather than guessed. This type said `string` and was a cast over the top of
 * the real shape, which is how a null reaches a Map lookup and comes back as
 * somebody else'"'"'s billing office.
 */
export type OfficeRow = {
  name: string;
  billing_office_id: string | null;
  address: string;
  phone: string;
  usor_district: string;
  note: string;
};

/** The ?bo= value for "clients with no billing office". */
export const NO_BILLING_OFFICE = "none";

/** A named person at a billing office, for one that has several (0195). */
export type BillingContact = {
  id: string;
  billing_office_id: string;
  name: string;
  title: string;
  email: string;
  phone: string;
  notes: string;
};

export async function readBillingOffices(supabase: SupabaseClient<Database>) {
  const [{ data: bos }, { data: offices }, { data: byClient }, { data: people }] = await Promise.all([
    supabase
      .from("billing_offices")
      .select("id, name, billing_email, has_group_address, contact_name, contact_title, contact_email, notes")
      .order("name"),
    supabase.from("offices").select("name, billing_office_id, address, phone, usor_district, note").order("name"),
    supabase.from("client_billing_office").select("client_id, billing_office_id"),
    supabase
      .from("billing_office_contacts")
      .select("id, billing_office_id, name, title, email, phone, notes")
      .order("name"),
  ]);

  const billingOffices = (bos ?? []) as BillingOffice[];
  const byId = new Map(billingOffices.map((b) => [b.id, b]));
  const officeRows = (offices ?? []) as OfficeRow[];
  const officeBilling = new Map(
    officeRows.map((o) => [o.name, o.billing_office_id ? (byId.get(o.billing_office_id) ?? null) : null]),
  );
  const clientBilling = new Map(
    (byClient ?? []).map((r) => [r.client_id as string, r.billing_office_id ? (byId.get(r.billing_office_id) ?? null) : null]),
  );

  // USOR Administration has eight; a CRP office has none, and shows its one
  // contact in the fields it has always had.
  const contacts = (people ?? []) as BillingContact[];
  const contactsByOffice = new Map<string, BillingContact[]>();
  for (const c of contacts) {
    contactsByOffice.set(c.billing_office_id, [...(contactsByOffice.get(c.billing_office_id) ?? []), c]);
  }

  return {
    billingOffices,
    offices: officeRows,
    contacts,
    contactsByOffice,
    byId,
    officeBilling,
    /** A client's billing office, or null when they have none. */
    forClient: (clientId: string | null | undefined): BillingOffice | null =>
      clientId ? (clientBilling.get(clientId) ?? null) : null,
  };
}

/** A ?bo= value, checked: a billing office's id, "none", or null for all. */
export function readBoParam(value: string | undefined | null, billingOffices: BillingOffice[]): string | null {
  if (!value) return null;
  if (value === NO_BILLING_OFFICE) return NO_BILLING_OFFICE;
  return billingOffices.some((b) => b.id === value) ? value : null;
}

/** Whether something billed through `bo` passes the filter `selected`. */
export function matchesBo(selected: string | null, bo: BillingOffice | null): boolean {
  if (!selected) return true;
  if (selected === NO_BILLING_OFFICE) return bo === null;
  return bo?.id === selected;
}

export type Recipients = {
  to: string;
  toLabel: string;
  cc: string;
  ccLabel: string;
  /** Said beside the addresses when the default is not the usual one. */
  note: string;
};

/**
 * Who anything emailed about a client goes to, by default: the billing office,
 * copying the client's counselor (owner, 18 Sept 2026). Where the two are the
 * same address - Spanish Fork's billing contact is also its counselor - it goes
 * once. Where the client has no billing office, the counselor is the To, as it
 * was before billing offices existed. Staff can change either before sending.
 */
export function recipientsFor(
  bo: BillingOffice | null,
  counselor: { name: string | null; email: string | null } | null,
): Recipients {
  const counselorEmail = (counselor?.email ?? "").trim();
  const counselorName = (counselor?.name ?? "").trim() || "the counselor";

  if (!bo) {
    return {
      to: counselorEmail,
      toLabel: counselorEmail ? `${counselorName} (counselor)` : "",
      cc: "",
      ccLabel: "",
      note: counselorEmail
        ? "This client has no billing office, so it goes to the counselor."
        : "This client has no billing office and no counselor email address. Add one before sending.",
    };
  }

  const same = counselorEmail.toLowerCase() === bo.billing_email.toLowerCase();
  return {
    to: bo.billing_email,
    toLabel: bo.name,
    cc: same ? "" : counselorEmail,
    ccLabel: same || !counselorEmail ? "" : `${counselorName} (counselor)`,
    note: !counselorEmail
      ? `No counselor email address is on file, so nobody is copied.`
      : same
        ? `${counselorName} is both the counselor and ${bo.name}'s billing contact, so it goes once.`
        : "",
  };
}
