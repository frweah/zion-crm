import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { can } from "@/lib/roles";
import { createClient } from "@/lib/supabase/server";
import { money, fmtStamp } from "@/lib/constants";
import { formsLabel, periodLabel, STATUS_MEANING, type ItemRow } from "@/lib/billing-items";
import { PageHead } from "../../../page-head";
import { ItemActions } from "./actions-panel";

/**
 * One billing item: what it is, whether it may be sent, and what has happened
 * to it (her §4, §11, §14).
 *
 * The checklist is the middle of the page rather than hidden behind the send
 * button, because on most items it is the answer to "why can I not send
 * this?" - and a list of what is missing is a list of what to do next.
 */
export default async function BillingItemPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data: row }, { data: gate }, { data: events }] = await Promise.all([
    supabase.from("billing_item_rows").select("*").eq("id", id).maybeSingle(),
    supabase.rpc("billing_item_gate", { p_item: id }),
    supabase
      .from("billing_item_events")
      .select("at, staff_name, was, became, note")
      .eq("item_id", id)
      .order("at", { ascending: false }),
  ]);

  if (!row) notFound();
  const item = row as unknown as ItemRow;
  const lines = (gate ?? []) as { line: string; passed: boolean; detail: string }[];
  const failing = lines.filter((l) => !l.passed);
  const canBill = can(me, "billing", "edit");

  return (
    <>
      <PageHead
        title={`${item.client_name} — ${item.service}`}
        context={`${periodLabel(item.period)} · ${item.status} — ${STATUS_MEANING[item.status] ?? ""}`}
      />

      <section className="page-section">
        <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(210px, 1fr))" }}>
          <div className="card">
            <div className="stat">
              {money(item.value)}
              <small>
                {item.billing_type === "Hourly" ? `${item.hours ?? 0} h × ${money(item.rate)}` : "flat fee"}
              </small>
            </div>
          </div>
          <div className="card">
            <div className="stat" style={{ fontSize: "var(--text-md)" }}>
              {item.auth_number ?? "none"}
              <small>authorization{item.auth_end ? `, ends ${item.auth_end}` : ""}</small>
            </div>
          </div>
          <div className="card">
            <div className="stat" style={{ fontSize: "var(--text-md)" }}>
              {formsLabel(item.usor_forms)}
              <small>required for this service</small>
            </div>
          </div>
          <div className="card">
            <div className="stat" style={{ fontSize: "var(--text-md)" }}>
              {item.assigned_staff ?? "nobody"}
              <small>has it</small>
            </div>
          </div>
        </div>
        <p className="lock">
          <Link href={`/clients/${item.client_id}?tab=billing`}>Open {item.client_name}&rsquo;s record</Link>
          {item.client_no ? ` · client ${item.client_no}` : ""}
        </p>
      </section>

      <section className="page-section">
        <h2 className="h2">Before it can be sent</h2>
        <p className="lock">
          {failing.length === 0
            ? "Every check passes. The packet is the signed authorization and the completed form."
            : `${failing.length} of ${lines.length} still to do.`}
        </p>
        <div className="card" style={{ padding: 0 }}>
          <table className="t" data-layout="the checklist before sending: a verdict, the check, and what it looked at">
            <tbody>
              {lines.map((l) => (
                <tr key={l.line}>
                  <td style={{ width: "1%" }}>
                    <span className={l.passed ? "chip" : "chip warn"}>{l.passed ? "ok" : "to do"}</span>
                  </td>
                  <td>{l.line}</td>
                  <td className="lock">{l.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {item.zero_hours_flagged && (
        <section className="page-section">
          <h2 className="h2">No hours logged this month</h2>
          <p className="lock">
            Far more often this is a month whose hours were never logged than a month with no service. Which was it?
          </p>
        </section>
      )}

      {canBill && <ItemActions item={item} ready={failing.length === 0} isAdmin={me.role === "Admin"} />}

      <section className="page-section">
        <h2 className="h2">What has happened to it</h2>
        {(events ?? []).length === 0 ? (
          <p className="empty">Nothing yet.</p>
        ) : (
          <div className="card" style={{ padding: 0 }}>
            <table className="t" data-layout="what has happened to this item: when, what changed, and who">
              <tbody>
                {(events ?? []).map((e, n) => (
                  <tr key={n}>
                    <td className="lock">{fmtStamp(e.at as string)}</td>
                    <td>
                      {e.was ? `${e.was} → ${e.became}` : e.became}
                      {e.note ? ` — ${e.note}` : ""}
                    </td>
                    <td className="lock">{(e.staff_name as string) ?? "the system"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}
