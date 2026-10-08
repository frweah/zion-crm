import { can } from "@/lib/roles";
import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, CAN_LOG_HOURS } from "@/lib/constants";
import { AddAuthorizationForm, ServiceEntryForm, type AuthOption } from "./billing-forms";
import { WarrantsToReview, loadWarrantsToReview } from "./warrants/review-section";
import { PageHead } from "../page-head";
import { DataTable, type DataRow } from "../data-table";
import { readBillingOffices, readBoParam, matchesBo } from "@/lib/billing-offices";
import { BillingOfficeFilter, withBo } from "../billing-office-filter";
import PendingAuthorizations from "./pending-authorizations";
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
 * Nothing that needs no action is shown (§§9, 11). "Show all" is a toggle.
 * Paid and Closed are not here at all - they are on the client's record under
 * History, and in Admin → Money.
 */
const TABS = ["authorizations", "hours"];

/** Where the tabs that were cut now live. A bookmark should still land somewhere. */
const GONE_TO_AUTHORIZATIONS = ["overview", "items", "invoices", "completions", "rates"];
const GONE_TO_HOURS = ["log", "service-log", "service_log", "servicelog", "service"];

export default async function BillingPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; show?: string; bo?: string; doc?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab, show, bo: rawBo, doc: rawDoc } = await searchParams;

  if (rawTab && GONE_TO_AUTHORIZATIONS.includes(rawTab)) redirect("/billing");
  if (rawTab && GONE_TO_HOURS.includes(rawTab)) redirect("/billing?tab=hours");
  const tab = TABS.includes(rawTab ?? "") ? rawTab! : "authorizations";

  const supabase = await createClient();
  const canBill = can(me, "billing", "edit");
  const canLog = CAN_LOG_HOURS.includes(me.role) || canBill;
  const showAll = show === "all";

  const [worklistResult, authsResult, clientsResult, entriesResult, billing] = await Promise.all([
    supabase.rpc("billing_worklist"),
    // What the hours form needs to offer, and what the log needs to name.
    supabase
      .from("authorizations")
      .select("id, client_id, number, service_type, total_hours, carried_used, rate_type, rate, status, parent_id, period")
      .order("number"),
    supabase.from("clients").select("id, name, status").order("name"),
    tab === "hours"
      ? supabase
          .from("service_entries")
          .select("id, auth_id, date, hours, non_billable, notes, primary_code, secondary_code, staff_id")
      : Promise.resolve({ data: [] as never[] }),
    readBillingOffices(supabase),
  ]);

  const worklist = (worklistResult.data ?? []) as WorklistRow[];
  const auths = authsResult.data ?? [];
  const clients = clientsResult.data ?? [];
  const entries = entriesResult.data ?? [];
  const clientName = new Map(clients.map((c) => [c.id, c.name]));

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
          <Link href="/billing/import" className="btn" style={{ textDecoration: "none" }}>
            Read an authorization
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

    const usedByAuth = new Map<string, number>();
    for (const a of auths) usedByAuth.set(a.id, Number(a.carried_used ?? 0));
    for (const e of entries) {
      if (e.non_billable) continue;
      usedByAuth.set(e.auth_id, (usedByAuth.get(e.auth_id) ?? 0) + Number(e.hours));
    }
    const toOption = (a: (typeof auths)[number]): AuthOption => ({
      id: a.id,
      label: `${a.number || "(no number)"} · ${clientName.get(a.client_id) ?? "—"} · ${a.service_type}`,
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
            empty="No hours logged yet. Hours can also be logged from the client's record, by whoever did the work."
          />
        </div>
      </>
    );
  }

  // ── Authorizations ────────────────────────────────────────
  const inOffice = worklist.filter((w) => matchesBo(bo, billing.forClient(w.client_id)));
  const needingAction = inOffice.filter((w) => (w.attention ?? "") !== "");
  const shown = showAll ? inOffice : needingAction;
  const quiet = inOffice.length - needingAction.length;

  return (
    <>
      {header}

      {/* §12.1: the authorizations the agent found, waiting for one click. */}
      {canBill && (
        <PendingAuthorizations
          selected={rawDoc && /^[0-9a-f-]{36}$/.test(rawDoc) ? rawDoc : null}
          hrefFor={(docId) => {
            const base = withBo(showAll ? "/billing?show=all" : "/billing", bo);
            return docId ? `${base}&doc=${docId}#from-documents` : `${base}#from-documents`;
          }}
        />
      )}

      {/* §9: Add authorization at the top of the page. */}
      {canBill && <AddAuthorizationForm clients={clients.filter((c) => c.status === "Active")} />}

      <BillingOfficeFilter
        billingOffices={billing.billingOffices}
        selected={bo}
        href={(b) => withBo(showAll ? "/billing?show=all" : "/billing", b)}
      />

      <div style={{ marginBottom: 8 }}>
        <div className="segmented">
          <Link href={withBo("/billing", bo)} className={showAll ? undefined : "on"}>
            Needs action ({needingAction.length})
          </Link>
          <Link href={withBo("/billing?show=all", bo)} className={showAll ? "on" : undefined}>
            Show all ({inOffice.length})
          </Link>
        </div>
      </div>

      <Worklist
        rows={shown}
        withClient
        empty={
          showAll
            ? "Nothing is being worked. Paid and closed authorizations are on the client's record, under History."
            : "Nothing needs attention today."
        }
      />

      {!showAll && quiet > 0 && (
        <p className="lock" style={{ margin: "0 0 14px" }}>
          {quiet} more {quiet === 1 ? "authorization is" : "authorizations are"} being worked and need
          nothing today.
        </p>
      )}

      {canBill && (
        <p className="lock" style={{ margin: "0 0 14px" }}>
          Have the PDF USOR sent? <Link href="/billing/import">Read the authorization off it</Link>{" "}
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
