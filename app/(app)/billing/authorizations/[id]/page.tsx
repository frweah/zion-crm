import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { can } from "@/lib/roles";
import { createClient } from "@/lib/supabase/server";
import { money, fmtStamp } from "@/lib/constants";
import { STATUS_MEANING, type AuthorizationStatus } from "@/lib/billing";
import { PageHead } from "../../../page-head";
import { AuthorizationFiles } from "../../../clients/[id]/authorization-files";
import { AuthorizationPayments } from "../../../clients/[id]/authorization-payments";
import { readPayments } from "@/lib/payments";
import { SubmitPacket, MarkDue, ServiceDates, MoveStale, CloseIt, ZeroHours } from "./panel";

/**
 * One authorization: what it is, whether it can be billed, and what has
 * happened to it (Billing Simplification Brief §§9, 12.3, 12.6, 13.11).
 *
 * §9 moved four screens onto this one. The forms, the signed authorization,
 * the submission checklist and Report & bill were each a tab somewhere; all
 * four were about this record, and a person billing had to hold four screens
 * in their head to answer one question. So: the one thing worth saying about
 * it at the top, then the checklist, then what is attached, then the moves.
 *
 * The checklist is the middle of the page rather than hidden behind the submit
 * button, because on most records it is the answer to "why can I not send
 * this?" - and a list of what is missing is a list of what to do next.
 */
export default async function AuthorizationPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data: rec }, { data: gate }, { data: events }, { data: files }, { data: entries }] =
    await Promise.all([
      supabase.from("authorization_record").select("*").eq("id", id).maybeSingle(),
      supabase.rpc("authorization_gate", { p_auth: id }),
      supabase
        .from("authorization_events")
        .select("at, staff_name, was, became, note")
        .eq("auth_id", id)
        .order("at", { ascending: false }),
      supabase
        .from("attachments")
        .select("id, storage_path, filename, category, auth_id, created_at, review_note")
        .eq("auth_id", id)
        .order("created_at", { ascending: false }),
      supabase
        .from("service_entries")
        .select("id, date, hours, non_billable, notes")
        .eq("auth_id", id)
        .order("date", { ascending: false }),
    ]);

  if (!rec) notFound();

  // The client's other files, so one of them can be attached here, and what
  // the inbox read off the ones that came through it. §11: the file exists
  // once, in the client's record, and this references it.
  const [{ data: loose }, { data: readings }, { data: corrections }, payments] = await Promise.all([
    supabase
      .from("attachments")
      .select("id, storage_path, filename, category, auth_id, created_at, review_note")
      .eq("client_id", rec.client_id as string)
      .is("auth_id", null)
      .order("created_at", { ascending: false }),
    supabase
      .from("inbox_documents")
      .select("storage_path, parsed, proposal")
      .eq("client_id", rec.client_id as string)
      .eq("kind", "Authorization"),
    supabase
      .from("authorization_corrections")
      .select("auth_id, at, field, was_value, new_value, reason, staff_name")
      .eq("auth_id", id)
      .order("at"),
    readPayments(supabase, [id]),
  ]);

  const readingByPath = new Map(
    (readings ?? []).map((d) => {
      const proposal = (d.proposal ?? {}) as { candidates?: { id: string }[] };
      const fields = ((d.parsed ?? {}) as { fields?: Record<string, { value: string }> }).fields ?? {};
      return [
        d.storage_path,
        {
          authIds: new Set((proposal.candidates ?? []).map((c) => c.id)),
          start: fields.startDate?.value ?? "",
          end: fields.endDate?.value ?? "",
        },
      ] as const;
    }),
  );
  const lines = (gate ?? []) as { line: string; passed: boolean; detail: string; blocking: boolean }[];
  const failing = lines.filter((l) => !l.passed);
  const stopping = failing.filter((l) => l.blocking);
  const canBill = can(me, "billing", "edit");
  const packet = (files ?? []).filter(
    (f) => f.category === "Authorization" || f.category === "Signed USOR form",
  );
  const monthName = rec.period
    ? new Date(`${rec.period}T00:00:00`).toLocaleDateString("en-US", { month: "long", year: "numeric" })
    : null;
  const settled = rec.status === "Paid" || rec.status === "Closed";

  return (
    <>
      <PageHead
        title={`${rec.client_name} — ${rec.service_type}${monthName ? `, ${monthName}` : ""}`}
        context={`${rec.number || "no USOR number"} · ${rec.status} — ${
          STATUS_MEANING[rec.status as AuthorizationStatus] ?? ""
        }`}
      />

      {/* §13.11: one line, not four alerts. */}
      {rec.attention ? (
        <section className="page-section">
          <p className={`alert ${Number(rec.urgency) <= 3 ? "bad" : ""}`}>{rec.attention}</p>
        </section>
      ) : null}

      <section className="page-section">
        <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(210px, 1fr))" }}>
          <div className="card">
            <div className="stat">
              {money(Number(rec.amount ?? 0))}
              <small>
                {rec.rate_type === "Hourly"
                  ? `${Number(rec.hours_logged ?? 0)} h × ${money(Number(rec.rate ?? 0))}`
                  : "flat fee"}
              </small>
            </div>
          </div>
          <div className="card">
            <div className="stat" style={{ fontSize: "var(--text-md)" }}>
              {rec.bill_by ?? "—"}
              <small>meant to be billed by</small>
            </div>
          </div>
          <div className="card">
            <div className="stat" style={{ fontSize: "var(--text-md)" }}>
              {rec.start_date ?? "—"} to {rec.end_date ?? "no end date"}
              <small>authorized</small>
            </div>
          </div>
          <div className="card">
            {/* §13.12: read from the client, and not editable here. */}
            <div className="stat" style={{ fontSize: "var(--text-md)" }}>
              {rec.counselor_name ?? "no counselor"}
              <small>{rec.billing_office_name ?? "no billing office"}</small>
            </div>
          </div>
        </div>
        <p className="lock">
          <Link href={`/clients/${rec.client_id}?tab=billing`}>
            Open {rec.client_name}&rsquo;s record
          </Link>
          {rec.client_no ? ` · client ${rec.client_no}` : ""}
          {rec.parent_id ? (
            <>
              {" · "}
              <Link href={`/billing/authorizations/${rec.parent_id}`}>
                one month of {rec.parent_number || "the coaching authorization"}
              </Link>
            </>
          ) : null}
        </p>
      </section>

      {rec.status === "Paid" ? (
        <section className="page-section">
          <h2 className="h2">Paid</h2>
          <p className="lock">
            {money(Number(rec.paid_amount ?? rec.amount ?? 0))} on {rec.paid_on}
            {rec.warrant ? ` · warrant ${rec.warrant}` : ""}
          </p>
        </section>
      ) : null}

      {rec.status === "Closed" ? (
        <section className="page-section">
          <h2 className="h2">Closed</h2>
          <p className="lock">
            {rec.closed_reason ?? "No reason recorded."}
            {rec.closed_at ? ` · ${fmtStamp(rec.closed_at as string)}` : ""}
          </p>
        </section>
      ) : null}

      {/* §12.3: every line the database can check, checked by the database. */}
      <section className="page-section">
        <h2 className="h2">Before it is submitted</h2>
        <p className="lock">
          {failing.length === 0
            ? "Every line passes. The packet is the signed authorization and the signed forms."
            : stopping.length > 0
              ? `${failing.length} of ${lines.length} still to do, and ${stopping.length} of those stops a submission.`
              : `${failing.length} of ${lines.length} still to do. None of them stops a submission.`}
        </p>
        <div className="card" style={{ padding: 0 }}>
          <table
            className="t"
            data-layout="the submission checklist: a verdict, the check, what it looked at, and whether it stops the submission"
          >
            <tbody>
              {lines.map((l) => (
                <tr key={l.line}>
                  <td style={{ width: "1%" }}>
                    <span className={l.passed ? "chip ok" : l.blocking ? "chip bad" : "chip warn"}>
                      {l.passed ? "ok" : l.blocking ? "stops this" : "to do"}
                    </span>
                  </td>
                  <td>{l.line}</td>
                  <td className="lock">{l.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {/* §§8, 9, 11: the packet is references to the client's file, not copies. */}
      <section className="page-section">
        <h2 className="h2">Its papers</h2>
        <AuthorizationFiles
          clientId={rec.client_id as string}
          authId={rec.id as string}
          authNumber={(rec.number as string) ?? ""}
          linked={files ?? []}
          available={(loose ?? []).map((f) => {
            const reading = f.storage_path ? readingByPath.get(f.storage_path) : undefined;
            return {
              ...f,
              suggested: Boolean(reading?.authIds.has(rec.id as string)),
              start: reading?.start ?? "",
              end: reading?.end ?? "",
            };
          })}
          canConfirm={canBill}
          paidOn={(rec.paid_on as string) ?? null}
          corrections={corrections ?? []}
        />
        <AuthorizationPayments payments={payments} status={rec.status as string} />
        {rec.missing_forms ? (
          <p className="lock">
            Still wanted for {rec.service_type}: {rec.missing_forms}.
          </p>
        ) : null}
      </section>

      {rec.rate_type === "Hourly" ? (
        <section className="page-section">
          <h2 className="h2">Hours on this record</h2>
          {(entries ?? []).length === 0 ? (
            <p className="empty">
              None logged. Hours are logged where the work happened, on the client&rsquo;s record.
            </p>
          ) : (
            <div className="card" style={{ padding: 0 }}>
              <table className="t" data-layout="hours logged against this authorization: the day, how many, and what was done">
                <tbody>
                  {(entries ?? []).map((e) => (
                    <tr key={e.id}>
                      <td className="lock">{e.date}</td>
                      <td>
                        {Number(e.hours)} h{e.non_billable ? " (not billable)" : ""}
                      </td>
                      <td className="lock">{e.notes ?? ""}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <p className="lock">
            {Number(rec.hours_on_the_authorization ?? 0)} of{" "}
            {rec.authorized_hours == null ? "—" : Number(rec.authorized_hours)} authorized hours used
            {rec.parent_id ? ", counted across every month of this authorization" : ""}.
          </p>
        </section>
      ) : null}

      {canBill && !settled ? (
        <section className="page-section">
          <h2 className="h2">What happens next</h2>
          <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))" }}>
            {rec.period && Number(rec.hours_logged ?? 0) === 0 && !rec.zero_hours_confirmed_at ? (
              <ZeroHours authId={rec.id as string} month={monthName ?? "this month"} />
            ) : null}
            <SubmitPacket
              authId={rec.id as string}
              ready={Boolean(rec.can_submit)}
              office={(rec.billing_office_email as string) ?? null}
              counselor={
                rec.counselor_email &&
                String(rec.counselor_email).toLowerCase() !==
                  String(rec.billing_office_email ?? "").toLowerCase()
                  ? (rec.counselor_email as string)
                  : null
              }
              attached={packet.length}
            />
            {rec.status === "Authorized" ? <MarkDue authId={rec.id as string} /> : null}
            <ServiceDates
              authId={rec.id as string}
              start={(rec.service_start as string) ?? null}
              end={(rec.service_end as string) ?? null}
            />
            <MoveStale authId={rec.id as string} staleDate={(rec.stale_date as string) ?? null} />
            <CloseIt authId={rec.id as string} />
          </div>
        </section>
      ) : null}

      <section className="page-section">
        <h2 className="h2">What has happened to it</h2>
        {(events ?? []).length === 0 ? (
          <p className="empty">Nothing yet.</p>
        ) : (
          <div className="card" style={{ padding: 0 }}>
            <table className="t" data-layout="what has happened to this authorization: when, what changed, and who">
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
