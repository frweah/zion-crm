import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, today, CAN_EDIT_BILLING } from "@/lib/constants";
import SettingsSection from "../settings/section";
import NoteTemplatesSection from "../note-templates/section";
import AccessLogSection from "../access/section";
import ExportsSection from "../exports/section";
import { MileageRateForm } from "../../hours/expenses";
import { SharedMailboxCard, type SharedMailboxRow } from "../../dashboard/shared-mailbox-card";

/**
 * Admin → System.
 *
 * Everything configured rather than worked: who the practice is, the rate
 * schedule, the mileage rate, the headings a note starts with, the shared
 * mailboxes read into the CRM - and the records kept about the system itself,
 * the access log and the monthly export. Nothing configurable sits in a
 * workflow screen any more.
 *
 * Billing reaches this page for the monthly export and the rate schedule; the
 * rest is Admin's, and is not shown to them.
 */
export default async function SystemPage({
  searchParams,
}: {
  searchParams: Promise<{ client?: string; who?: string; subject?: string; days?: string; month?: string }>;
}) {
  const me = await requireStaff();
  if (!CAN_EDIT_BILLING.includes(me.role)) redirect("/dashboard");
  const isAdmin = me.role === "Admin";

  const supabase = await createClient();
  const [{ data: rates }, { data: mileageRates }, { data: mailboxes }] = await Promise.all([
    supabase.from("rate_schedule").select("service, sub, fee, unit, funding_source").order("service"),
    isAdmin
      ? supabase.from("mileage_rates").select("effective_from, cents_per_mile, note").order("effective_from", { ascending: false })
      : Promise.resolve({ data: [] }),
    isAdmin
      ? supabase
          .from("shared_mailboxes")
          .select("address, label, last_run_at, last_mail_sync_at, mail_logged, last_error")
          .order("address")
      : Promise.resolve({ data: [] }),
  ]);

  const divider = { marginTop: 40, paddingTop: 24, borderTop: "1px solid var(--line)" };

  return (
    <>
      <nav className="row2 no-print" aria-label="On this page" style={{ gap: 16, marginBottom: 12, fontSize: 13, flexWrap: "wrap" }}>
        {isAdmin && <a href="#organization">Organization</a>}
        <a href="#rates">Rate schedule</a>
        {isAdmin && <a href="#mileage">Mileage rate</a>}
        {isAdmin && <a href="#note-headings">Note headings</a>}
        {isAdmin && <a href="#integrations">Integrations</a>}
        {isAdmin && <a href="#access-log">Access log</a>}
        <a href="#export">Monthly export</a>
      </nav>

      {isAdmin && (
        <section id="organization">
          <SettingsSection />
        </section>
      )}

      <section id="rates" style={isAdmin ? divider : undefined}>
        <h1 className="h1" style={{ fontSize: 22 }}>
          Rate schedule
        </h1>
        <p className="sub">
          The CRP rate schedule from the Voc Rehab Workbook. New authorizations are pre-filled from
          it, and it is keyed by funding source so a second funder can be added without code
          changes.
        </p>
        <div className="card" style={{ padding: 0, overflowX: "auto" }}>
          <table className="t">
            <thead>
              <tr>
                <th>Service</th>
                <th>Subcategory</th>
                <th>Approved fee</th>
                <th>Unit</th>
                <th>Funder</th>
              </tr>
            </thead>
            <tbody>
              {(rates ?? []).map((r, i) => (
                <tr key={i}>
                  <td>{r.service}</td>
                  <td>{r.sub}</td>
                  <td>{money(r.fee)}</td>
                  <td>{r.unit}</td>
                  <td>{r.funding_source}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {isAdmin && (
        <section id="mileage" style={divider}>
          <h1 className="h1" style={{ fontSize: 22 }}>
            Mileage rate
          </h1>
          <p className="sub">
            What a mile claimed on Hours is paid at. Rates are dated, so a claim is priced at the rate
            that applied on the day it was driven.
          </p>
          <MileageRateForm rates={(mileageRates ?? []) as never} today={today()} />
        </section>
      )}

      {isAdmin && (
        <section id="note-headings" style={divider}>
          <NoteTemplatesSection />
        </section>
      )}

      {isAdmin && (
        <section id="integrations" style={divider}>
          <h1 className="h1" style={{ fontSize: 22 }}>
            Integrations
          </h1>
          <p className="sub">
            Shared mailboxes read into client records. Each person connects their own Outlook from
            the Dashboard, and the documents agent&apos;s last run is shown on{" "}
            <Link href="/admin/documents">Admin → Documents</Link>.
          </p>
          <SharedMailboxCard mailboxes={(mailboxes ?? []) as SharedMailboxRow[]} />
        </section>
      )}

      {isAdmin && (
        <section id="access-log" style={divider}>
          <AccessLogSection searchParams={searchParams} />
        </section>
      )}

      <section id="export" style={divider}>
        <ExportsSection searchParams={searchParams} />
      </section>
    </>
  );
}
