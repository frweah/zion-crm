import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PageHead } from "../../../page-head";
import { SharedMailboxCard, type SharedMailboxRow } from "../../../dashboard/shared-mailbox-card";

/** Mailboxes read into client records (Design language, §3). */
export default async function MailboxSettings() {
  await requireAdmin();
  const supabase = await createClient();
  const { data: mailboxes } = await supabase
    .from("shared_mailboxes")
    .select("address, label, last_run_at, last_mail_sync_at, mail_logged, last_error")
    .order("address");

  return (
    <>
      <PageHead title="Shared mailboxes" context="Mailboxes read into client records" />
      <p className="sub">Each person connects their own Outlook from Home; these are the practice&apos;s shared ones.</p>
      <SharedMailboxCard mailboxes={(mailboxes ?? []) as SharedMailboxRow[]} />
    </>
  );
}
