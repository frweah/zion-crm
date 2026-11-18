import Link from "next/link";
import { money, PRACTICE_TZ } from "@/lib/constants";
import type { BoardAuthorization } from "@/lib/billing-board-shape";
import { moneyStrip, type HoursLine, type JobStanding, type LastContact, type ReportStanding } from "@/lib/client-dashboard-shape";

/**
 * The client record's front page (client dashboard brief, Part 3).
 *
 * What it is for: somebody opens a client and knows, without opening a tab,
 * what the client is owed and owes, where this month's report is, where the
 * job search has got to, what is on somebody's list, and what has happened.
 * Every one of those was a tab away, and the money was on two.
 *
 * Nothing here is a second place to edit anything. The authorizations card is
 * the board's own component with the board's own cells; everything else is
 * read, and every figure links to the screen that owns it.
 *
 * Each section is its own component so that hiding one from a role later is a
 * line in the page rather than an unpicking (brief, Part 3, visibility).
 */

const day = (iso: string | null) =>
  iso
    ? new Date(iso.length === 10 ? `${iso}T00:00:00` : iso).toLocaleDateString("en-US", {
        timeZone: PRACTICE_TZ,
        weekday: "short",
        month: "short",
        day: "numeric",
      })
    : "";

const dayAndYear = (iso: string | null) =>
  iso
    ? new Date(iso.length === 10 ? `${iso}T00:00:00` : iso).toLocaleDateString("en-US", {
        timeZone: PRACTICE_TZ,
        month: "short",
        day: "numeric",
        year: "numeric",
      })
    : "";

/** Hours as the practice writes them: 6.5, not 6.50 and not 6 hours 30. */
const hrs = (n: number) => (Math.round(n * 100) / 100).toLocaleString("en-US", { maximumFractionDigits: 2 });

/** Draft, Reviewed, Signed, Sent — in the colour each one means. */
function reportChip(status: string) {
  if (status === "Sent") return "chip ok";
  if (status === "Signed" || status === "Reviewed") return "chip";
  return "chip warn";
}

export function MoneyStrip({
  clientId,
  rows,
  hours,
  report,
}: {
  clientId: string;
  rows: BoardAuthorization[];
  hours: HoursLine[];
  report: ReportStanding | null;
}) {
  const m = moneyStrip(rows);
  const billing = `/clients/${clientId}?tab=billing`;
  return (
    <div className="tiles">
      <Link className="tile" href={billing}>
        <span className="tile-label">Authorized</span>
        <span className="tile-value">{money(m.authorized)}</span>
        <span className="tile-note">
          {m.authorizations} {m.authorizations === 1 ? "authorization" : "authorizations"}
        </span>
      </Link>

      <Link className="tile" href={billing}>
        <span className="tile-label">Billed</span>
        <span className="tile-value">{money(m.billed)}</span>
        <span className="tile-note">
          {m.invoices === 0
            ? "nothing invoiced yet"
            : `${m.invoices} ${m.invoices === 1 ? "invoice" : "invoices"}${m.invoiceNumber ? ` · ${m.invoiceNumber}` : ""}`}
        </span>
      </Link>

      <Link className={`tile${m.needsInvoice > 0 ? " tile-bad" : ""}`} href={billing}>
        <span className="tile-label">Outstanding</span>
        <span className="tile-value">{money(m.outstanding)}</span>
        <span className="tile-note">
          {m.needsInvoice > 0
            ? `${m.needsInvoice} needs invoice`
            : m.outstanding > 0
              ? "invoiced, waiting on payment"
              : "nothing owed"}
        </span>
      </Link>

      <Link className="tile" href={billing}>
        <span className="tile-label">Paid</span>
        <span className="tile-value" style={m.paid > 0 ? { color: "var(--ok)" } : undefined}>
          {money(m.paid)}
        </span>
        <span className="tile-note">{m.lastPaidOn ? `last ${day(m.lastPaidOn)}` : "nothing paid yet"}</span>
      </Link>

      <div className="tile">
        <span className="tile-label">Hours this month</span>
        {hours.length === 0 ? (
          <>
            <span className="tile-value">—</span>
            <span className="tile-note">no hourly authorization</span>
          </>
        ) : (
          <>
            {hours.map((h) => (
              <span key={h.service} className="tile-note" style={{ display: "flex", justifyContent: "space-between", gap: 10 }}>
                <span>{h.service}</span>
                <b style={{ fontVariantNumeric: "tabular-nums" }}>{hrs(h.hours)}</b>
              </span>
            ))}
            <span className="lock">one line per hourly authorization</span>
          </>
        )}
      </div>

      <Link className="tile" href={`/clients/${clientId}?tab=documents`}>
        <span className="tile-label">This month&rsquo;s report</span>
        {report ? (
          <>
            <span className={reportChip(report.status)} style={{ alignSelf: "flex-start" }}>
              {report.status}
            </span>
            <span className="tile-note">
              {report.status === "Sent" ? `sent ${day(report.sent_at)}` : `due ${day(report.due_on)}`}
            </span>
          </>
        ) : (
          <>
            <span className="tile-value">—</span>
            <span className="tile-note">none raised yet</span>
          </>
        )}
      </Link>
    </div>
  );
}

export function WhereTheyAre({ clientId, jobs }: { clientId: string; jobs: JobStanding }) {
  return (
    <section className="card" style={{ marginBottom: 14 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
        <h3 style={{ margin: 0 }}>Where they are</h3>
        <Link className="lock" href={`/clients/${clientId}?tab=jobs`}>
          All applications →
        </Link>
      </div>

      <div className="tiles" style={{ marginTop: 10, marginBottom: 0 }}>
        <div className="tile">
          <span className="tile-label">Job status</span>
          <span className="tile-value" style={{ fontSize: "var(--text-lg)" }}>
            {jobs.status ?? "Not started"}
          </span>
          <span className="tile-note">{jobs.since ? `since ${day(jobs.since)}` : "nothing reported yet"}</span>
        </div>

        <div className="tile">
          <span className="tile-label">Applications</span>
          <span className="tile-value">{jobs.open} open</span>
          <span className="tile-note">
            {jobs.byStatus.length
              ? jobs.byStatus.map((s) => `${s.count} ${s.status.toLowerCase()}`).join(" · ")
              : "none open"}
          </span>
        </div>

        <div className="tile">
          <span className="tile-label">Last placement</span>
          <span className="tile-value" style={{ fontSize: "var(--text-lg)" }}>
            {jobs.lastPlacement?.employer || "—"}
          </span>
          <span className="tile-note">
            {jobs.lastPlacement
              ? [jobs.lastPlacement.title, dayAndYear(jobs.lastPlacement.start_date)].filter(Boolean).join(" · ")
              : "none yet"}
          </span>
        </div>
      </div>

      {jobs.next.length > 0 && (
        <table className="t" data-layout="what is next on this client's job search" style={{ marginTop: 12 }}>
          <tbody>
            {jobs.next.map((n) => (
              <tr key={`${n.match_id}-${n.status}-${n.when}`}>
                <td style={{ width: 110 }}>{n.status}</td>
                <td style={{ width: 180 }}>
                  <span className="chip">{n.employer}</span>
                </td>
                <td>
                  {n.detail}
                  {n.when && <span className="lock"> {day(n.when)}</span>}
                </td>
                <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>{n.who}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}

/**
 * The line under the header: who the client is to us, how to reach them, and
 * when somebody last did. The numbers and the people are edited on Profile;
 * this says what they are so that ringing somebody is not a tab away.
 */
export function ContactStrip({
  clientId,
  counselorName,
  office,
  numbers,
  contacts,
  lastContact,
}: {
  clientId: string;
  counselorName: string | null;
  office: string | null;
  numbers: { phone: string; label: string; can_text: boolean | null; state: string | null; whose: string }[];
  contacts: { name: string; relationship: string; phone: string | null; may_speak_for: boolean }[];
  lastContact: LastContact;
}) {
  const mine = numbers.filter((n) => n.whose === "Client");
  return (
    <section className="card contact-strip" style={{ marginBottom: 14 }}>
      <div>
        <span className="tile-label">Counselor</span>
        <div>
          {counselorName || "not set"}
          {office ? ` · ${office}` : ""}
        </div>
      </div>

      <div>
        <span className="tile-label">Phone</span>
        <div>
          {mine.length === 0 ? (
            <Link href={`/clients/${clientId}?tab=profile`}>No number on file</Link>
          ) : (
            mine.map((n) => (
              <div key={n.phone}>
                {n.phone} <span className="lock">{n.label.toLowerCase()}</span>{" "}
                {n.can_text ? (
                  <span className="chip ok">texts ok</span>
                ) : (
                  <span className="chip bad">{n.state === "Withdrawn" ? "replied STOP" : "no consent"}</span>
                )}
              </div>
            ))
          )}
        </div>
      </div>

      <div>
        <span className="tile-label">Family contact</span>
        <div>
          {contacts.length === 0 ? (
            <span className="lock">nobody recorded</span>
          ) : (
            contacts.slice(0, 2).map((c) => (
              <div key={c.name}>
                {c.name} <span className="lock">({c.relationship || "contact"})</span>
                {c.phone ? ` · ${c.phone}` : ""}{" "}
                {c.may_speak_for && <span className="chip ok">may speak for them</span>}
              </div>
            ))
          )}
        </div>
      </div>

      <div>
        <span className="tile-label">Last contact</span>
        <div>
          {lastContact ? (
            <>
              {day(lastContact.at)} · {lastContact.channel}
            </>
          ) : (
            <span className="lock">nothing recorded</span>
          )}
        </div>
      </div>
    </section>
  );
}

/** The authorizations card's heading, over the board's own grid. */
export function AuthorizationsCard({
  rows,
  children,
}: {
  rows: BoardAuthorization[];
  children: React.ReactNode;
}) {
  return (
    <section className="card" style={{ marginBottom: 14 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
        <h3 style={{ margin: 0 }}>Authorizations</h3>
        <Link className="lock" href="/billing?tab=authorizations">
          Open in Billing board →
        </Link>
      </div>
      {rows.length === 0 ? (
        <p className="empty" style={{ margin: "10px 0 0" }}>
          Nothing authorized yet — add the first authorization on the Billing tab.
        </p>
      ) : (
        <div style={{ marginTop: 10 }}>{children}</div>
      )}
    </section>
  );
}
