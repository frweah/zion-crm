import { can } from "@/lib/roles";
import Link from "next/link";
import { authorizationNumberLabel } from "@/lib/billing";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, CAN_LOG_HOURS } from "@/lib/constants";
import {
  AddAuthorizationForm,
  ServiceEntryForm,
  type AuthOption,
  type ServiceRate,
} from "./billing-forms";
import { WarrantsToReview, loadWarrantsToReview } from "./warrants/review-section";
import { PageHead } from "../page-head";
import { DataTable, type DataRow } from "../data-table";
import { readBillingOffices, readBoParam, matchesBo } from "@/lib/billing-offices";
import { BillingOfficeFilter, withBo } from "../billing-office-filter";
import PendingAuthorizations from "./pending-authorizations";
import { ImportForm } from "./import/import-form";
import { Worklist, type WorklistRow } from "./worklist";
import { isLive } from "@/lib/billing";

/**
 * Billing: two tabs (Billing Simplification Brief §9).
 *
 * There were seven places to look - Overview, Items, Authorizations, Service
 * log, Invoices, Report & bill, Forms, Export - and all seven were about the
 * same records. §9 cut it to Authorizations and Hours, and §12.6 put the forms,
 * the signed authorization, the checklist and Report & bill on the
 * authorization record where they belong.
 *
 * The working list is one list (§12.2). There is no separate Due section,
 * because Due is one of the things a row can say about itself, and a list
 * split by status makes a person look in two places for the same job. It is
 * ordered by what is most pressing and then by the day it was meant to be
 * billed.
 *
 * Nothing that needs no action is shown (§§9, 11). Three views: what needs
 * action, all of it, and Stale - the ones past the grace, which can no longer
 * be submitted and are there to be closed in a batch (owner, 19 Oct 2026).
 * Paid and Closed are not here at all - they are on the client's record under
 * History, and in Admin → Money.
 */
const TABS = ["authorizations", "hours"];

/** Where the tabs that were cut now live. A bookmark should still land somewhere. */
const GONE_TO_AUTHORIZATIONS = ["overview", "items", "invoices", "completions", "rates"];
const GONE_TO_HOURS = ["log", "service-log", "service_log", "servicelog", "service"];

/**
 * The hours log is read a month at a time, sixty rows to a page.
 *
 * It used to ask for every service entry ever logged, with no filter and no
 * limit, and serialise the lot into the page. That was free while the table
 * was empty and would not have stayed free: the practice logs hours daily
 * against every coaching month, and the screen only ever shows a period
 * (stress test finding 2, owner 16 Oct 2026).
 */
const LOG_PAGE = 60;

/** The month a log page is showing, as the first of that month. */
function logMonth(raw: string | undefined): string {
  if (raw && /^\d{4}-\d{2}$/.test(raw)) return `${raw}-01`;
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-01`;
}

/** The month before or after one, as YYYY-MM. */
function shiftMonth(first: string, by: number): string {
  const d = new Date(`${first}T00:00:00`);
  d.setMonth(d.getMonth() + by);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}

export default async function BillingPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; show?: string; bo?: string; doc?: string; month?: string; page?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab, show, bo: rawBo, doc: rawDoc, month: rawMonth, page: rawPage } = await searchParams;

  if (rawTab && GONE_TO_AUTHORIZATIONS.includes(rawTab)) redirect("/billing");
  if (rawTab && GONE_TO_HOURS.includes(rawTab)) redirect("/billing?tab=hours");
  const tab = TABS.includes(rawTab ?? "") ? rawTab! : "authorizations";

  const monthStart = logMonth(rawMonth);
  const monthEnd = `${shiftMonth(monthStart, 1)}-01`;
  const logPage = Math.max(0, Number(rawPage ?? 0) || 0);

  const supabase = await createClient();
  const canBill = can(me, "billing", "edit");
  const canLog = CAN_LOG_HOURS.includes(me.role) || canBill;
  const showAll = show === "all";
  const showStale = show === "stale";

  const [worklistResult, authsResult, clientsResult, entriesResult, billing, ratesResult] = await Promise.all([
    supabase.rpc("billing_worklist"),
    // What the hours form needs to offer, and what the log needs to name.
    supabase
      .from("authorizations")
      .select("id, client_id, number, service_type, total_hours, carried_used, rate_type, rate, status, parent_id, period")
      .order("number"),
    supabase.from("clients").select("id, name, status, agency_id").order("name"),
    // The month on screen, that page of it. Never the whole table.
    tab === "hours"
      ? supabase
          .from("service_entries")
          .select("id, auth_id, date, hours, non_billable, notes, primary_code, secondary_code, staff_id")
          .gte("date", monthStart)
          .lt("date", monthEnd)
          .order("date", { ascending: false })
          .order("created_at", { ascending: false })
          .range(logPage * LOG_PAGE, logPage * LOG_PAGE + LOG_PAGE - 1)
      : Promise.resolve({ data: [] as never[] }),
    readBillingOffices(supabase),
    // §13.13: the rate comes from the schedule, which Admin can change, and
    // never from a constant in the code.
    supabase.from("rate_schedule").select("crm_service, fee, unit, service, sub").not("crm_service", "is", null),
  ]);

  const worklist = (worklistResult.data ?? []) as WorklistRow[];
  const auths = authsResult.data ?? [];
  const clients = clientsResult.data ?? [];
  const entries = entriesResult.data ?? [];
  const clientName = new Map(clients.map((c) => [c.id, c.name]));

  // One entry per service: every row that prices a service carries the same
  // fee and unit, so the last one read is the figure.
  const rates: Record<string, ServiceRate> = {};
  for (const r of ratesResult.data ?? []) {
    if (!r.crm_service) continue;
    rates[r.crm_service] = {
      fee: Number(r.fee),
      rateType: r.unit === "per hour" ? "Hourly" : "Flat Fee",
      basis: `The rate schedule: ${r.service}${r.sub ? `, ${r.sub}` : ""}`,
    };
  }

  const bo = readBoParam(rawBo, billing.billingOffices);

  const header = (
    <PageHead
      title="Billing"
      context={
        tab === "hours"
          ? "Hours logged against coaching authorizations"
          : "Every authorization waiting to be billed, chased or paid"
      }
      actions={
        canBill ? (
          <Link href="/billing#new-authorization" className="btn" style={{ textDecoration: "none" }}>
            Add authorization
          </Link>
        ) : undefined
      }
    />
  );

  // ── Hours ─────────────────────────────────────────────────
  // The log records hours and prices nothing (§10). There is no billing action
  // on it, and it cannot create a record: hours land on the coaching month and
  // the month works out what it comes to.
  if (tab === "hours") {
    const staffResult = await supabase.from("staff").select("id, name");
    const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));
    const authById = new Map(auths.map((a) => [a.id, a]));
    const hourly = auths.filter((a) => a.rate_type === "Hourly" && isLive(a.status) && a.parent_id === null);

    /**
     * How many hours each authorization has used — from the database, not
     * from the rows on this page.
     *
     * It was counted here, over whatever entries the page had loaded, per
     * authorization and its own entries only. That was wrong twice over: it
     * missed every hour logged on a coaching month (so a parent showing 40
     * used read 0), and now that the log is one month at a time it would see
     * only that month. authorization_hours_used (0205) is the same function
     * check_entry_hours enforces with, so the figure the form shows is the
     * figure the database will hold it to.
     */
    const { data: usedRows } = await supabase.rpc("authorization_hours_used", {
      p_auths: auths.map((a) => a.id),
    });
    // A function's output columns are nullable to the type generator; this
    // one never returns a null id, since it selects them from what was asked.
    const usedByAuth = new Map<string, number>(
      (usedRows ?? []).flatMap((r) => (r.auth_id ? [[r.auth_id, Number(r.used)] as [string, number]] : [])),
    );
    const toOption = (a: (typeof auths)[number]): AuthOption => ({
      id: a.id,
      label: `${authorizationNumberLabel(a)} · ${clientName.get(a.client_id) ?? "—"} · ${a.service_type}`,
      serviceType: a.service_type,
      rateType: a.rate_type,
      rate: Number(a.rate),
      totalHours: a.total_hours == null ? null : Number(a.total_hours),
      used: usedByAuth.get(a.id) ?? 0,
    });

    const logRows: DataRow[] = [...entries]
      .sort((a, b) => b.date.localeCompare(a.date))
      .map((e) => {
        const a = authById.get(e.auth_id);
        const client = a ? (clientName.get(a.client_id) ?? "—") : "—";
        const staff = e.staff_id ? (staffName.get(e.staff_id) ?? "—").split(" ")[0] : "—";
        return {
          key: e.id,
          cells: {
            date: e.date,
            auth: a ? (
              <Link href={`/billing/authorizations/${a.id}`} style={{ color: "var(--teal)" }}>
                {a.number || (a.period ? new Date(`${a.period}T00:00:00`).toLocaleDateString("en-US", { month: "short", year: "numeric" }) : "—")}
              </Link>
            ) : (
              "—"
            ),
            client,
            hours: (
              <>
                {e.hours}
                {e.non_billable && (
                  <span className="chip" style={{ marginLeft: 6 }}>
                    non-billable
                  </span>
                )}
              </>
            ),
            staff,
            notes: (
              <>
                {e.primary_code && (
                  <span className="chip" style={{ marginRight: 4 }}>
                    #{e.primary_code}
                    {e.secondary_code ? `/${e.secondary_code}` : ""}
                  </span>
                )}
                {e.notes}
              </>
            ),
          },
          sort: { hours: Number(e.hours), notes: e.notes ?? "" },
          text: [e.date, a?.number, client, staff, e.notes, e.primary_code, e.non_billable ? "non-billable" : ""]
            .filter(Boolean)
            .join(" "),
        };
      });

    return (
      <>
        {header}
        <div className="alert">
          Log hours on the date the service actually happened. Coaching hours land on that
          month&apos;s record on their own, and the month works out what it comes to — nothing here
          prices anything or raises a bill.
        </div>

        {canLog && <ServiceEntryForm auths={hourly.map(toOption)} />}

        {/* The month being read. Hours belong to a month everywhere else in
            billing, so the log is read the same way. */}
        <nav className="segmented no-print" aria-label="The month of hours shown">
          <Link href={`/billing?tab=hours&month=${shiftMonth(monthStart, -1)}`}>Earlier</Link>
          <span aria-current="page">
            {new Date(`${monthStart}T00:00:00`).toLocaleDateString("en-US", {
              month: "long",
              year: "numeric",
            })}
          </span>
          <Link href={`/billing?tab=hours&month=${shiftMonth(monthStart, 1)}`}>Later</Link>
        </nav>

        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="service entries"
            columns={[
              { key: "date", label: "Date" },
              { key: "auth", label: "Authorization" },
              { key: "client", label: "Client" },
              { key: "hours", label: "Hours", align: "right" },
              { key: "staff", label: "Staff" },
              { key: "notes", label: "Notes" },
            ]}
            rows={logRows}
            empty="No hours logged in this month. Hours can also be logged from the client's record, by whoever did the work."
          />
        </div>

        {(logPage > 0 || logRows.length === LOG_PAGE) && (
          <nav className="pager no-print" aria-label="Pages of hours">
            {logPage > 0 && (
              <Link href={`/billing?tab=hours&month=${monthStart.slice(0, 7)}&page=${logPage - 1}`}>
                Newer
              </Link>
            )}
            {logRows.length === LOG_PAGE && (
              <Link href={`/billing?tab=hours&month=${monthStart.slice(0, 7)}&page=${logPage + 1}`}>
                Older
              </Link>
            )}
          </nav>
        )}
      </>
    );
  }

  // ── Authorizations ────────────────────────────────────────
  const inOffice = worklist.filter((w) => matchesBo(bo, billing.forClient(w.client_id)));
  const needingAction = inOffice.filter((w) => (w.attention ?? "") !== "");
  /**
   * Stale: past the grace, so it can no longer be submitted (owner, 19 Oct).
   *
   * The flag comes from the database (0221) rather than from reading the
   * attention sentence, because the sentence is copy and copy gets rewritten.
   * These are the rows with nothing left to do but close, which is why the
   * filter and the bulk close belong on the same screen.
   */
  const stale = inOffice.filter((w) => w.blocked);
  const shown = showStale ? stale : showAll ? inOffice : needingAction;
  const quiet = inOffice.length - needingAction.length;

  return (
    <>
      {header}

      {/* §12.1: the authorizations the agent found, waiting for one click. */}
      {canBill && (
        <PendingAuthorizations
          selected={rawDoc && /^[0-9a-f-]{36}$/.test(rawDoc) ? rawDoc : null}
          /**
           * Where Open on a row of the confirm queue goes: this page, with the
           * document chosen, which is the view with its PDF and the
           * pick-and-confirm form beside it (§9).
           *
           * Built with URLSearchParams rather than by appending "&doc=". It
           * used to append, which worked while the base was
           * "/billing?tab=authorizations" and always carried a "?" - and §9
           * made the base "/billing". The href became
           * "/billing&doc=<id>#from-documents", where "&doc=<id>" is part of
           * the path and not a parameter, so every row of the queue answered
           * 404. Composing the query means there is no arrangement of the
           * filters where the separator is wrong.
           */
          hrefFor={(docId) => {
            const params = new URLSearchParams();
            if (showAll) params.set("show", "all");
            if (showStale) params.set("show", "stale");
            if (docId) params.set("doc", docId);
            const query = params.toString();
            return withBo(`/billing${query ? `?${query}` : ""}`, bo) + "#from-documents";
          }}
        />
      )}

      {/*
        §§9, 12.1: Add authorization at the top of the page, and the PDF is the
        way in.

        "Drop a PDF - the number, dates, service, rate and hours are read off it
        - confirm - saved, with the PDF referenced." The typed form is the
        fallback for a scan with no text in it, which is why it is behind a fold
        rather than gone: a photographed authorization still has to be typed, and
        a rate keyed as 4.50 instead of 45.00 is not noticed until the payment is
        short.
      */}
      {canBill && (
        <section id="new-authorization" className="page-section">
          <h2 className="h2">Add authorization</h2>
          <ImportForm clients={clients.filter((c) => c.status !== "Closed")} />
          <details className="card" style={{ marginTop: 12 }}>
            <summary>How this reads a file</summary>
            <p className="sub" style={{ marginTop: 8 }}>
              Rules, not judgement. The PDF is opened here, its text is read, and each field is
              found by a labelled pattern &mdash; &ldquo;Total Hours&rdquo; followed by a number,
              &ldquo;Rate&rdquo; followed by an amount. Nothing is sent to any outside service, no
              model sees a client&apos;s authorization, and the same file gives the same answer
              every time.
            </p>
            <p className="sub">
              That also sets the limits. A label the rules do not know is left blank rather than
              guessed at, and a scanned or photographed authorization has no text to read at all.
              The rules live in one file with names on them, so a field that comes out wrong on a
              real USOR form is a rule to fix rather than a mystery.
            </p>
          </details>
          <details className="card" style={{ marginTop: 12 }}>
            <summary>No text in the PDF? Type it in instead</summary>
            <p className="lock">
              A scanned or photographed authorization has no text to read, so there is nothing to
              check against. Everything below is typed, and the rate comes from the rate schedule.
            </p>
            <AddAuthorizationForm clients={clients.filter((c) => c.status === "Active")} rates={rates} />
          </details>
        </section>
      )}

      <BillingOfficeFilter
        billingOffices={billing.billingOffices}
        selected={bo}
        href={(b) => withBo(showStale ? "/billing?show=stale" : showAll ? "/billing?show=all" : "/billing", b)}
      />

      <div style={{ marginBottom: 8 }}>
        <div className="segmented">
          <Link href={withBo("/billing", bo)} className={showAll ? undefined : "on"}>
            Needs action ({needingAction.length})
          </Link>
          <Link href={withBo("/billing?show=all", bo)} className={showAll ? "on" : undefined}>
            Show all ({inOffice.length})
          </Link>
          <Link href={withBo("/billing?show=stale", bo)} className={showStale ? "on" : undefined}>
            Stale ({stale.length})
          </Link>
        </div>
      </div>

      <Worklist
        canClear={canBill}
        rows={shown}
        withClient
        empty={
          showStale
            ? "Nothing is past the grace - every authorization here can still be submitted."
            : showAll
              ? "Nothing is being worked. Paid and closed authorizations are on the client's record, under History."
              : "Nothing needs attention today."
        }
      />

      {!showAll && !showStale && quiet > 0 && (
        <p className="lock" style={{ margin: "0 0 14px" }}>
          {quiet} more {quiet === 1 ? "authorization is" : "authorizations are"} being worked and need
          nothing today.
        </p>
      )}

      {canBill && (
        <p className="lock" style={{ margin: "0 0 14px" }}>
          Have the PDF USOR sent? <Link href="/billing#new-authorization">Read the authorization off it</Link>{" "}
          instead of typing it — a rate keyed as 4.50 instead of 45.00 is not noticed until the
          payment is short.
        </p>
      )}

      {/* §9: warrant matching stays here. One warrant at a time, no totals. */}
      <section id="warrant-review" style={{ marginTop: 32 }}>
        <WarrantsToReview data={loadWarrantsToReview()} />
      </section>
    </>
  );
}
