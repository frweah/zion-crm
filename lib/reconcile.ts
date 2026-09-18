import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { money, today } from "@/lib/constants";
import { ORG } from "@/lib/roles";
import type { BillingOffice } from "@/lib/billing-offices";

/**
 * "Reconcile with office": one email to a CRP billing office listing what is
 * still owed and what is about to lapse unbilled.
 *
 * What goes in it is the database's answer (billing_office_reconciliation,
 * 0091) - every Sent invoice not yet paid, and every open authorization ending
 * within 30 days with value not yet invoiced. This turns it into words, and
 * works out who to copy: the counselor on each case listed.
 *
 * Built twice for every send - once to show the draft, and again on the server
 * when it is sent - so what is logged against each case is what was true when
 * the email went, not what the page held when it was opened.
 */

export const ENDING_WITHIN_DAYS = 30;

export type ReconRow = {
  kind: string;
  client_id: string;
  client_name: string;
  counselor_id: string | null;
  counselor_name: string | null;
  counselor_email: string | null;
  auth_id: string;
  auth_number: string | null;
  service: string | null;
  invoice_number: string | null;
  amount: number | null;
  sent_on: string | null;
  days_outstanding: number | null;
  end_date: string | null;
  unbilled: number | null;
};

export type Reconciliation = {
  to: string;
  cc: string[];
  counselorsWithoutEmail: string[];
  subject: string;
  body: string;
  unpaid: ReconRow[];
  ending: ReconRow[];
  unpaidTotal: number;
  /** One entry per client listed, for the contact log. */
  cases: { client_id: string; client_name: string; counselor_id: string | null; lines: string[] }[];
};

const UNPAID = "Unpaid invoice";

export async function buildReconciliation(
  supabase: SupabaseClient<Database>,
  bo: BillingOffice,
  senderName: string,
): Promise<{ ok: true; recon: Reconciliation } | { ok: false; error: string }> {
  const { data, error } = await supabase.rpc("billing_office_reconciliation", {
    p_billing_office: bo.id,
    p_within_days: ENDING_WITHIN_DAYS,
  });
  if (error) return { ok: false, error: error.message };

  const rows = ((data ?? []) as ReconRow[]).map((r) => ({
    ...r,
    amount: r.amount === null ? null : Number(r.amount),
    unbilled: r.unbilled === null ? null : Number(r.unbilled),
  }));

  // Oldest debt first: that is the question the email is really asking.
  const unpaid = rows
    .filter((r) => r.kind === UNPAID)
    .sort((a, b) => (b.days_outstanding ?? 0) - (a.days_outstanding ?? 0) || a.client_name.localeCompare(b.client_name));
  const ending = rows
    .filter((r) => r.kind !== UNPAID)
    .sort((a, b) => (a.end_date ?? "").localeCompare(b.end_date ?? "") || a.client_name.localeCompare(b.client_name));
  const unpaidTotal = unpaid.reduce((t, r) => t + (r.amount ?? 0), 0);

  // The counselor on each case, once each. The billing office's own address is
  // never copied to itself - Spanish Fork's contact is also its counselor.
  const copy = new Map<string, string>();
  const withoutEmail = new Set<string>();
  for (const r of [...unpaid, ...ending]) {
    const email = (r.counselor_email ?? "").trim();
    if (email) {
      if (email.toLowerCase() !== bo.billing_email.toLowerCase()) copy.set(email.toLowerCase(), email);
    } else if (r.counselor_name) {
      withoutEmail.add(r.counselor_name);
    }
  }

  const unpaidLine = (r: ReconRow) =>
    `- ${r.client_name} · ${r.auth_number || "(no V-number)"} · ${r.service || "—"} · ${money(r.amount ?? 0)} · ` +
    `sent ${r.sent_on ?? "—"} · ${r.days_outstanding ?? 0} days outstanding`;
  const endingLine = (r: ReconRow) =>
    `- ${r.client_name} · ${r.auth_number || "(no V-number)"} · ${r.service || "—"} · ends ${r.end_date ?? "—"} · ` +
    `${money(r.unbilled ?? 0)} not yet invoiced`;

  const hello = bo.contact_name.trim() ? `Hello ${bo.contact_name.trim().split(/\s+/)[0]},` : "Hello,";
  const parts: string[] = [
    hello,
    "",
    `${ORG.name} (vendor ${ORG.vendor}) would like to reconcile the following with ${bo.name}.`,
    "",
  ];
  if (unpaid.length) {
    parts.push(
      `Invoices sent and not yet paid - ${unpaid.length}, ${money(unpaidTotal)} in all:`,
      ...unpaid.map(unpaidLine),
      "",
    );
  }
  if (ending.length) {
    parts.push(
      `Authorizations ending in the next ${ENDING_WITHIN_DAYS} days with value not yet invoiced - ${ending.length}:`,
      ...ending.map(endingLine),
      "",
    );
  }
  parts.push(
    unpaid.length
      ? "Could you let us know where each unpaid invoice stands, and whether you need anything further from us to process it?"
      : "We are letting you know before these lapse, in case anything is needed from your side.",
    "",
    "Thank you,",
    senderName,
    ORG.name,
    `${ORG.phone} · ${ORG.email}`,
  );

  const byClient = new Map<string, Reconciliation["cases"][number]>();
  for (const r of unpaid) {
    const c = byClient.get(r.client_id) ?? { client_id: r.client_id, client_name: r.client_name, counselor_id: r.counselor_id, lines: [] };
    c.lines.push(`${r.auth_number || "(no V-number)"} ${money(r.amount ?? 0)} unpaid, ${r.days_outstanding ?? 0} days`);
    byClient.set(r.client_id, c);
  }
  for (const r of ending) {
    const c = byClient.get(r.client_id) ?? { client_id: r.client_id, client_name: r.client_name, counselor_id: r.counselor_id, lines: [] };
    c.lines.push(`${r.auth_number || "(no V-number)"} ends ${r.end_date}, ${money(r.unbilled ?? 0)} not invoiced`);
    byClient.set(r.client_id, c);
  }

  return {
    ok: true,
    recon: {
      to: bo.billing_email,
      cc: [...copy.values()],
      counselorsWithoutEmail: [...withoutEmail].sort(),
      subject: `Reconciliation - ${ORG.name} - ${bo.name} - ${today()}`,
      body: parts.join("\n"),
      unpaid,
      ending,
      unpaidTotal,
      cases: [...byClient.values()],
    },
  };
}
