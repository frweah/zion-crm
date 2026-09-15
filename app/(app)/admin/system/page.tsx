import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, today, CAN_EDIT_BILLING } from "@/lib/constants";
import { PageHead } from "../../page-head";
import SettingsSection from "../settings/section";
import NoteTemplatesSection from "../note-templates/section";
import AccessLogSection from "../access/section";
import ExportsSection from "../exports/section";
import { AgentStatus } from "../inbox/agent-status";
import { TaxYearEditor, type TaxYearRow } from "../contractors/contractor-forms";
import { MileageRateForm } from "../../hours/expenses";
import { SharedMailboxCard, type SharedMailboxRow } from "../../dashboard/shared-mailbox-card";

/**
 * Admin → System.
 *
 * Everything configured rather than worked: who the practice is, the rate
 * schedule, the tax years a 1099 run depends on, the mileage rate, the
 * headings a note starts with, the documents agent and the shared mailboxes -
 * and the records kept about the system itself, the access log and the monthly
 * export. Nothing configurable sits in a workflow screen any more.
 *
 * Billing reaches this page for the rate schedule, the agent's status and the
 * monthly export; the rest is Admin's, and is not shown to them.
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
  const [{ data: rates }, { data: mileageRates }, { data: mailboxes }, { data: years }, { data: staff }] = await Promise.all([
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
    isAdmin ? supabase.from("tax_years").select("*").order("year", { ascending: false }) : Promise.resolve({ data: [] }),
    isAdmin ? supabase.from("staff").select("id, name") : Promise.resolve({ data: [] }),
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

  const toc: [string, string][] = [];
  if (isAdmin) toc.push(["organization", "Organization"]);
  toc.push(["rates", "Rate schedule"]);
  if (isAdmin) toc.push(["tax-years", "Tax years"], ["mileage", "Mileage rate"], ["note-headings", "Note headings"]);
  toc.push(["agent", "Documents agent"]);
  if (isAdmin) toc.push(["integrations", "Shared mailboxes"], ["access-log", "Access log"]);
  toc.push(["export", "Monthly export"]);

  return (
    <>
      <PageHead
        title="System"
        context={
          isAdmin
            ? "How the practice is set up, and the records kept about the system itself"
            : "The rate schedule, the documents agent, and the month as files"
        }
        toc={toc}
      />

      {isAdmin && (
        <section id="organization" className="page-section">
          <SettingsSection />
        </section>
      )}

      <section id="rates" className="page-section">
        <h2 className="h2">Rate schedule</h2>
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
        <section id="tax-years" className="page-section">
          <h2 className="h2">Tax years</h2>
          <p className="sub">
            The federal 1099-NEC threshold and the Utah state copy for each year. A 1099 run on{" "}
            <Link href="/admin/people#contractors">Admin → People</Link> will not build on a year
            whose threshold nobody has confirmed.
          </p>
          {yearRows.length === 0 ? (
            <div className="empty">No tax years are set up.</div>
          ) : (
            yearRows.map((y) => <TaxYearEditor key={y.year} row={y} />)
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

      <section id="agent" className="page-section">
        <h2 className="h2">Documents agent</h2>
        <p className="sub">
          The program on the office PC that reads the client folders and posts what it finds to{" "}
          <Link href="/admin/documents">Admin → Documents</Link>. It runs every fifteen minutes when
          the machine is on.
        </p>
        <AgentStatus />
      </section>

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

      <section id="export" className="page-section">
        <ExportsSection searchParams={searchParams} />
      </section>
    </>
  );
}
