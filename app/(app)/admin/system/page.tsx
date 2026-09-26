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

  const toc: [string, string][] = [
    ["organization", "Organization"],
    ["website-chat", "Website chat"],
    ["tax-years", "Tax years"],
    ["mileage", "Mileage rate"],
    ["note-headings", "Note headings"],
    ["integrations", "Shared mailboxes"],
    ["access-log", "Access log"],
  ];

  return (
    <>
      <PageHead
        title="System"
        context="How the practice is set up, and the records kept about the system itself"
        toc={toc}
      />

      {isAdmin && (
        <section id="organization" className="page-section">
          <SettingsSection />
        </section>
      )}

      {isAdmin && (
        <section id="website-chat" className="page-section">
          <h2 className="h2">Website chat</h2>
          <p className="sub">
            The bubble on zionrehabcenter.com. What somebody says there arrives in{" "}
            <Link href="/messages/texts?show=web">Texts &amp; web</Link>, beside the texts, and joins a client&apos;s
            record as soon as it is matched to one.
          </p>
          {webChatError && (
            <div className="alert bad">
              These settings could not be read ({webChatError}), so what is shown below is not what is saved. Do not
              save over them until that is fixed.
            </div>
          )}
          <WebChatSettingsForm
            settings={chat}
            staff={staff ?? []}
            live={Boolean(webLive)}
            embed={`<script src="${process.env.NEXT_PUBLIC_SITE_URL ?? "https://crm.zionvocrehab.com"}/widget.js" async></script>`}
          />
        </section>
      )}

      {isAdmin && (
        <section id="tax-years" className="page-section">
          <h2 className="h2">Tax years</h2>
          <p className="sub">
            The federal 1099-NEC threshold and the Utah state copy for each year. A 1099 run on{" "}
            <Link href="/admin/people?tab=contractors">HR → Contractors</Link> will not build on a year
            whose threshold nobody has confirmed.
          </p>
          {yearRows.length === 0 ? (
            <div className="empty">No tax years are set up.</div>
          ) : (
            // One list, a year to an item: each is its own form, not a card apiece.
            <div className="list">
              {yearRows.map((y) => (
                <TaxYearEditor key={y.year} row={y} />
              ))}
            </div>
          )}
        </section>
      )}

      {isAdmin && (
        <section id="mileage" className="page-section">
          <h2 className="h2">Mileage rate</h2>
          <p className="sub">
            What a mile claimed on Hours is paid at. Rates are dated, so a claim is priced at the rate
            that applied on the day it was driven.
          </p>
          <MileageRateForm rates={(mileageRates ?? []) as never} today={today()} />
        </section>
      )}

      {isAdmin && (
        <section id="note-headings" className="page-section">
          <NoteTemplatesSection />
        </section>
      )}

      {isAdmin && (
        <section id="integrations" className="page-section">
          <h2 className="h2">Shared mailboxes</h2>
          <p className="sub">
            Mailboxes read into client records. Each person connects their own Outlook from the
            Dashboard.
          </p>
          <SharedMailboxCard mailboxes={(mailboxes ?? []) as SharedMailboxRow[]} />
        </section>
      )}

      {isAdmin && (
        <section id="access-log" className="page-section">
          <AccessLogSection searchParams={searchParams} />
        </section>
      )}

    </>
  );
}
