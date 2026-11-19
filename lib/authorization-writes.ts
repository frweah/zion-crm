import "server-only";
import type { createClient } from "@/lib/supabase/server";
import type { Database } from "@/lib/database.types";

type Supabase = Awaited<ReturnType<typeof createClient>>;
type Patch = Database["public"]["Tables"]["authorizations"]["Update"];

/**
 * The one way a server action changes an authorization, and it counts the rows
 * (owner, 19 November 2026).
 *
 * Eight writes across two files were `update(...).eq("id", id)` reporting
 * success on whatever came back - which for PostgREST includes "no error,
 * nothing changed": a policy that refuses, a row somebody deleted while the
 * list was on screen, an id that was never there. The screen then said "Ready
 * to bill" over a record that had not moved. That is the `sms_messages` fault,
 * in Billing.
 *
 * The ruling named three, which were the three the fault report named: Mark
 * ready to bill, the move to Submitted after the packet sends, and Closed with
 * the reason. Reading the file to change them found four more of exactly the
 * same shape - the stale date, the service dates, the zero-hours answer and
 * the close that answer can make - and Money's follow-up, which was already
 * counting its rows and is here so that one answer covers all of them. Three
 * fixed and five left would have been the next report.
 *
 * Exactly one row, not at least one: the where clause is a primary key, so two
 * would mean something underneath this had changed shape, and reporting
 * success on that is how the first fault happened.
 *
 * It lives here rather than in either action file because a `"use server"`
 * module may only export actions - exporting anything else from one is the
 * 19 October outage, where React refused the module on first require and every
 * billing action answered "Application error". `server-only` keeps it off the
 * client, and `check-status-writes.mjs` fails any server action that writes the
 * table without it.
 *
 * The `select("id")` needs the read policy as well as the write one, which
 * `authorizations_read` gives every active staff member - a RETURNING that
 * cannot read its own row comes back as a refusal rather than as silence.
 *
 * Returns null when the one row changed, and the sentence to show when it did
 * not.
 */
export async function writeOne(
  supabase: Supabase,
  id: string,
  patch: Patch,
  what: string,
): Promise<string | null> {
  const { data, error } = await supabase
    .from("authorizations")
    .update(patch)
    .eq("id", id)
    .select("id");
  // The database's own sentence, which names the field. Ours could not.
  if (error) return error.message.replace(/^.*?:\s*/, "").trim() || error.message;
  const n = data?.length ?? 0;
  if (n === 1) return null;
  if (n === 0) {
    return `Nothing was ${what} — that authorization is not on your list any more. Open Billing again and see what it says.`;
  }
  return `${n} authorizations would have been ${what}, so none was. Say what you were doing before anybody tries again.`;
}
