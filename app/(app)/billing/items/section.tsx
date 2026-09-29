import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/constants";
import {
  ITEM_STATUSES,
  OURS,
  THEIRS,
  STATUS_MEANING,
  formsLabel,
  periodLabel,
  type ItemRow,
} from "@/lib/billing-items";
import { DataTable } from "../../data-table";

/**
 * Billing → Overview and Billing → Items (her §13/§24).
 *
 * Overview is not a dashboard of numbers for their own sake: it is "what is
 * waiting, and on whom". Ours and theirs are separated because they are
 * different kinds of waiting - one is work somebody here has not done, the
 * other is a letter that has not come back - and a morning spent on the first
 * is worth more than a morning spent staring at the second.
 *
 * Items is her column list, in her order.
 */
async function readItems(): Promise<ItemRow[]> {
  const supabase = await createClient();
  const { data } = await supabase
    .from("billing_item_rows")
    .select("*")
    .order("period", { ascending: false, nullsFirst: false })
    .order("client_name");
  return (data ?? []) as unknown as ItemRow[];
}

export async function BillingOverview({ hrefFor }: { hrefFor: (status: string | null) => string }) {
  const items = await readItems();
  // Open coaching authorizations with no dates: no month could be opened for
  // them, and no date was invented for them either (0127).
  const supabase = await createClient();
  const { data: undated } = await supabase
    .from("billing_items_undated")
    .select("auth_id, number, client_id, client_name, service_type")
    .order("client_name");
  const count = (s: string) => items.filter((i) => i.status === s).length;
  const valueOf = (list: ItemRow[]) => list.reduce((sum, i) => sum + (i.value ?? 0), 0);

  const ours = items.filter((i) => (OURS as readonly string[]).includes(i.status));
  const theirs = items.filter((i) => (THEIRS as readonly string[]).includes(i.status));
  const flagged = items.filter((i) => i.zero_hours_flagged);
  const overdue = items.filter((i) => i.followup_due && i.followup_due <= new Date().toISOString().slice(0, 10));

  if (items.length === 0) {
    return (
      <section className="page-section">
        <p className="empty">
          No billing items yet. They arrive when an authorization is confirmed, and each month for Job Coaching.
        </p>
      </section>
    );
  }

  return (
    <>
      <section className="page-section">
        <h2 className="h2">Waiting on us</h2>
        <p className="lock">
          {ours.length} {ours.length === 1 ? "item" : "items"}, {money(valueOf(ours))} of work that has not been sent.
        </p>
        <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))" }}>
          {ITEM_STATUSES.filter((s) => (OURS as readonly string[]).includes(s)).map((s) => (
            <Link key={s} href={hrefFor(s)} className="card" style={{ textDecoration: "none", color: "inherit" }}>
              <div className="stat">
                {count(s)}
                <small>
                  {s.toLowerCase()} — {STATUS_MEANING[s]}
                </small>
              </div>
            </Link>
          ))}
        </div>
      </section>

      <section className="page-section">
        <h2 className="h2">Waiting on USOR</h2>
        <p className="lock">
          {theirs.length} {theirs.length === 1 ? "item" : "items"}, {money(valueOf(theirs))} sent and not yet paid.
        </p>
        <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))" }}>
          {ITEM_STATUSES.filter((s) => (THEIRS as readonly string[]).includes(s)).map((s) => (
            <Link key={s} href={hrefFor(s)} className="card" style={{ textDecoration: "none", color: "inherit" }}>
              <div className="stat">
                {count(s)}
                <small>
                  {s.toLowerCase()} — {STATUS_MEANING[s]}
                </small>
              </div>
            </Link>
          ))}
          <Link href={hrefFor("Paid")} className="card" style={{ textDecoration: "none", color: "inherit" }}>
            <div className="stat">
              {count("Paid")}
              <small>paid — {money(valueOf(items.filter((i) => i.status === "Paid")))} in</small>
            </div>
          </Link>
        </div>
      </section>

      {(undated ?? []).length > 0 && (
        <section className="page-section">
          <h2 className="h2">Authorizations with no dates</h2>
          <p className="lock">
            {(undated ?? []).length} open {(undated ?? []).length === 1 ? "authorization has" : "authorizations have"} no
            start or end date, so no month could be opened for {(undated ?? []).length === 1 ? "it" : "them"}. Nothing
            was guessed: add the dates and the months open by themselves.
          </p>
          <div className="card" style={{ padding: 0 }}>
            <table className="t" data-layout="authorizations waiting for their dates: client, number and service">
              <tbody>
                {(undated ?? []).map((a) => (
                  <tr key={a.auth_id as string}>
                    <td>
                      <Link href={`/clients/${a.client_id}?tab=billing`}>{a.client_name as string}</Link>
                    </td>
                    <td>{(a.number as string) ?? "no number"}</td>
                    <td className="lock">{a.service_type as string}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {(flagged.length > 0 || overdue.length > 0 || count("Closed") > 0) && (
        <section className="page-section">
          <h2 className="h2">Needs a person</h2>
          <ul className="lock" style={{ lineHeight: 1.8 }}>
            {flagged.length > 0 && (
              <li>
                <Link href={hrefFor("flagged")}>
                  {flagged.length} coaching {flagged.length === 1 ? "month" : "months"} with no hours logged
                </Link>{" "}
                — almost always a month nobody logged, not a month nothing happened.
              </li>
            )}
            {overdue.length > 0 && (
              <li>
                <Link href={hrefFor("followup")}>{overdue.length} sent with no answer</Link> — 14 days or more.
              </li>
            )}
            {count("Closed") > 0 && (
              <li>
                <Link href={hrefFor("Closed")}>{count("Closed")} closed</Link> — ended without payment, each with a
                recorded reason.
              </li>
            )}
          </ul>
        </section>
      )}
    </>
  );
}

export async function BillingItems({ filter }: { filter: string | null }) {
  const items = await readItems();
  const today = new Date().toISOString().slice(0, 10);
  const shown = !filter
    ? items
    : filter === "flagged"
      ? items.filter((i) => i.zero_hours_flagged)
      : filter === "followup"
        ? items.filter((i) => i.followup_due && i.followup_due <= today)
        : items.filter((i) => i.status === filter);

  return (
    <section className="page-section">
      <h2 className="h2">
        Items{filter ? ` — ${filter === "flagged" ? "no hours logged" : filter === "followup" ? "no answer yet" : filter.toLowerCase()}` : ""}
      </h2>
      {filter && (
        <p className="lock">
          <Link href="/billing?tab=items">Show all items</Link>
        </p>
      )}
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="items"
          sortBy
          pageSize={50}
          columns={[
            { key: "client", label: "Client" },
            { key: "service", label: "Service" },
            { key: "period", label: "Period" },
            { key: "auth", label: "Authorization" },
            { key: "status", label: "Billing status" },
            { key: "form", label: "USOR form" },
            { key: "value", label: "Amount", align: "right" },
            { key: "who", label: "Assigned" },
            { key: "sent", label: "Sent" },
            { key: "paid", label: "Paid" },
          ]}
          rows={shown.map((i) => ({
            key: i.id,
            cells: {
              client: (
                <Link href={`/billing/items/${i.id}`}>
                  {i.client_name}
                  {i.client_no ? ` · ${i.client_no}` : ""}
                </Link>
              ),
              service: i.service,
              period: periodLabel(i.period),
              auth: i.auth_number ?? "none attached",
              status: (
                <>
                  {i.status}
                  {i.zero_hours_flagged && <span className="chip warn">no hours</span>}
                  {i.correction_note && <span className="chip warn">correction</span>}
                </>
              ),
              form: formsLabel(i.usor_forms),
              value: money(i.value),
              who: i.assigned_staff ?? "—",
              sent: i.submitted_at ? i.submitted_at.slice(0, 10) : "—",
              paid: i.paid_on ?? "—",
            },
            sort: {
              client: i.client_name,
              service: i.service,
              period: i.period ?? "",
              auth: i.auth_number ?? "",
              status: i.status,
              value: i.value ?? 0,
              who: i.assigned_staff ?? "",
              sent: i.submitted_at ?? "",
              paid: i.paid_on ?? "",
            },
          }))}
          empty="Nothing here yet."
        />
      </div>
    </section>
  );
}
