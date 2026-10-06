import Link from "next/link";
import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { PageHead } from "../../page-head";
import SettingsSection from "../settings/section";
import NoteTemplatesSection from "../note-templates/section";
import AccessLogSection from "../access/section";
import { TaxYearEditor, type TaxYearRow } from "../contractors/contractor-forms";
import { MileageRateForm } from "../../hours/expenses";
import { SharedMailboxCard, type SharedMailboxRow } from "../../dashboard/shared-mailbox-card";
import { WebChatSettingsForm, type WebChatSettings } from "./web-chat";

/**
 * Admin → System.
 *
 * Everything configured rather than worked: who the practice is, the tax
 * years a 1099 run depends on, the mileage rate, the headings a note starts
 * with and the shared mailboxes - and the access log. Admin's alone (owner,
 * 19 Sept 2026): the rate schedule and the monthly export are Billing → Export
 * now, and the documents agent's status is on Billing → Documents.
 */
export default async function SystemPage({
  searchParams,
}: {
  searchParams: Promise<{ client?: string; who?: string; subject?: string; days?: string }>;
}) {
  await requireAdmin();
  const isAdmin = true;

  const supabase = await createClient();
  const [{ data: mileageRates }, { data: mailboxes }, { data: years }, { data: staff }, { data: webChat, error: webChatFailure }, { data: webLive }] = await Promise.all([
    isAdmin
      ? supabase.from("mileage_rates").select("effective_from, cents_per_mile, note").order("effective_from", { ascending: false })
      : Promise.resolve({ data: [] }),
    isAdmin
      ? supabase
          .from("shared_mailboxes")
          .select("address, label, last_run_at, last_mail_sync_at, mail_logged, last_error")
          .order("address")
      : Promise.resolve({ data: [] }),
    isAdmin ? supabase.from("tax_years").select("*").order("year", { ascending: false }) : Promise.resolve({ data: [] }),
    isAdmin ? supabase.from("staff").select("id, name").eq("active", true).eq("is_system", false).order("name") : Promise.resolve({ data: [] }),
    supabase
      .from("org_settings")
      .select("web_chat_enabled, web_chat_takers, web_chat_open, web_chat_close, web_chat_days, web_chat_greeting, web_chat_promise")
      .maybeSingle(),
    // Live is not a setting: it is whether anybody who takes chats has a
    // window open right now, inside the hours below.
    supabase.rpc("web_chat_live"),
  ]);

  const staffName = new Map(((staff ?? []) as { id: string; name: string }[]).map((s) => [s.id, s.name]));
  const yearRows: TaxYearRow[] = ((years ?? []) as {
    year: number;
    federal_threshold: number | null;
    utah_state_copy: boolean;
    confirmed_on: string | null;
    confirmed_by: string | null;
    notes: string;
  }[]).map((y) => ({
    year: y.year,
    federal_threshold: y.federal_threshold,
    utah_state_copy: y.utah_state_copy,
    confirmed_on: y.confirmed_on,
    confirmed_by_name: y.confirmed_by ? (staffName.get(y.confirmed_by) ?? null) : null,
    notes: y.notes,
  }));

  // A refused read of this table arrives as an empty row rather than as
  // nothing, so it has to be said out loud: defaults shown as if they were
  // the practice's settings would be a screen quietly lying.
  const chat = (webChat ?? {
    web_chat_enabled: false,
    web_chat_takers: [],
    web_chat_open: "09:00",
    web_chat_close: "17:00",
    web_chat_days: [1, 2, 3, 4, 5],
    web_chat_greeting: "",
    web_chat_promise: "",
  }) as WebChatSettings;

  const webChatError = webChatFailure?.message ?? null;

  const toc: [string, string][] = [["access-log", "Access log"]];

  return (
    <>
      <PageHead
        title="System"
        context="The records the system keeps about itself"
        toc={toc}
      />

      {/* Each feature's settings are their own page now (Design language,
          §3). What is left here is the practice's record of itself. */}
      <section className="page-section">
        <p className="sub">
          Settings moved to <Link href="/admin/settings-hub">Settings</Link>, a page per feature: the practice, the
          website chat, work and hours, note headings, shared mailboxes and tax years.
        </p>
      </section>

      {isAdmin && (
        <section id="access-log" className="page-section">
          <AccessLogSection searchParams={searchParams} />
        </section>
      )}

    </>
  );
}
