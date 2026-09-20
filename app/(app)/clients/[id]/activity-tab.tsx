import Link from "next/link";
import { clientTabFor } from "@/lib/client-tabs";
import { ExcludeThread } from "./calendar-tab";
import { startClientThread } from "../../messages/actions";

export type ActivityRow = {
  at: string;
  kind: string;
  title: string;
  detail: string;
  who: string | null;
  tab: string;
  ref_id: string;
};

/** What a feed row can act on, beyond opening where it lives. */
export type FeedExtras = {
  mail: Record<string, { web_link: string; conversation_id: string }>;
  events: Record<string, { outlook_web_link: string | null }>;
};

/** The kinds, in the order the chips are shown. */
export const ACTIVITY_KINDS = [
  "Note",
  "Job",
  "Interview",
  "Follow-up",
  "Task",
  "Form",
  "Counselor",
  "Stage",
  "Placement",
  "Retention",
  "Appointment",
  "Mail",
  "Text",
  "Chat",
  "Website",
  "Hours",
  "Payment",
] as const;

const WINDOWS = [
  { days: 30, label: "Last 30 days" },
  { days: 90, label: "Last 90 days" },
  { days: 365, label: "Last year" },
  { days: 0, label: "Everything" },
];

const JOB_KINDS = new Set(["Job", "Interview", "Follow-up"]);

/**
 * Where an item goes when you click it.
 *
 * Most things live on a tab of this client's record. The feed was written
 * against the twelve tabs, so its tab names are mapped to the six that took
 * them in; a job's dates live on Jobs, not Profile. Counselor contacts are
 * kept against the counselor, on their own screen. A staff thread about this
 * client opens on Messages, where it is read and answered; a chat somebody
 * started on the website opens in the inbox it arrived in.
 */
function hrefFor(clientId: string, row: ActivityRow): string {
  if (row.tab === "chat") return `/messages?c=${row.ref_id}`;
  if (row.tab === "web") return `/messages/texts?show=web&c=${row.ref_id}`;
  if (row.tab === "counselors") return "/counselors";
  const tab = JOB_KINDS.has(row.kind) ? "jobs" : clientTabFor(row.tab);
  return `/clients/${clientId}?tab=${tab}`;
}

const dayOf = (iso: string) =>
  new Date(iso).toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
  });

export function ActivityTab({
  clientId,
  clientName,
  rows,
  days,
  kind,
  counts,
  extras,
  colleagues,
}: {
  clientId: string;
  clientName: string;
  rows: ActivityRow[];
  days: number;
  kind: string | null;
  counts: Map<string, number>;
  extras: FeedExtras;
  colleagues: { id: string; name: string }[];
}) {
  const base = `/clients/${clientId}?tab=activity`;
  const keep = (k: string | null, d: number) =>
    `${base}${k ? `&kind=${encodeURIComponent(k)}` : ""}${d ? `&days=${d}` : "&days=0"}`;

  // Grouped by day, so a week of activity reads as a few days rather than as
  // thirty separate lines each repeating its own date.
  const byDay = new Map<string, ActivityRow[]>();
  for (const row of rows) {
    const day = row.at.slice(0, 10);
    const list = byDay.get(day) ?? [];
    list.push(row);
    byDay.set(day, list);
  }

  return (
    <>
      {/* The window and the kind are filters, so they are segmented choices rather than tabs. */}
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="segmented" aria-label="How far back">
          {WINDOWS.map((w) => (
            <Link key={w.days} href={keep(kind, w.days)} className={w.days === days ? "on" : ""}>
              {w.label}
            </Link>
          ))}
        </div>

        <div className="segmented" aria-label="What kind" style={{ display: "flex", marginTop: 10 }}>
          <Link href={keep(null, days)} className={kind === null ? "on" : ""}>
            Everything
          </Link>
          {ACTIVITY_KINDS.filter((k) => (counts.get(k) ?? 0) > 0).map((k) => (
            <Link key={k} href={keep(k, days)} className={kind === k ? "on" : ""}>
              {k} {counts.get(k)}
            </Link>
          ))}
        </div>

        <p className="lock" style={{ marginTop: 10, marginBottom: 0 }}>
          Everything already recorded elsewhere, in one order. Each item opens where it lives.
        </p>
      </div>

      {/*
        A conversation about a client belongs on the client's record, which is
        why it is started here rather than on Messages: it lands in this feed,
        it is exported with the record, and only the people in it - and Admin -
        can read it (Messaging brief, B).
      */}
      <details className="card" style={{ marginBottom: 14 }}>
        <summary>Talk to a colleague about {clientName}</summary>
        <form action={startClientThread} style={{ marginTop: 10 }}>
          <input type="hidden" name="client_id" value={clientId} />
          <div className="row2">
            <label className="field" style={{ flex: 2 }}>
              What it is about (optional)
              <input name="title" maxLength={80} placeholder={`e.g. ${clientName}'s work schedule`} />
            </label>
            <label className="field">
              Who to bring in
              <select name="staff_id" multiple size={Math.min(5, Math.max(3, colleagues.length))}>
                {colleagues.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <button className="btn gold" type="submit" style={{ marginTop: 8 }}>
            Start the thread
          </button>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            It shows here as a Chat item, and a document of theirs can be attached to it by reference - never copied,
            and never to somebody who could not open it anyway.
          </p>
        </form>
      </details>

      {rows.length === 0 ? (
        <div className="card">
          <p className="sub" style={{ margin: 0 }}>
            Nothing in this window.{" "}
            {days > 0 && (
              <Link href={keep(kind, 0)}>Look at everything instead</Link>
            )}
            {kind && (
              <>
                {" "}
                Or <Link href={keep(null, days)}>drop the {kind} filter</Link>.
              </>
            )}
          </p>
        </div>
      ) : (
        /*
          One container for the feed, a day to each item. The rows under a day
          are a feed read top to bottom in time order, not a list to sort or
          filter, so they stay a plain layout table.
        */
        <div className="list">
        {[...byDay.entries()].map(([day, items]) => (
          <div key={day} className="list-item">
            <h3 style={{ margin: 0, fontSize: "var(--text-md)" }}>
              {dayOf(items[0].at)}
            </h3>
            <table className="t" data-layout="one day of the activity feed">
              <tbody>
                {items.map((row) => {
                  const mail = row.kind === "Mail" ? extras.mail[row.ref_id] : undefined;
                  const event = row.kind === "Appointment" ? extras.events[row.ref_id] : undefined;
                  const outlook = mail?.web_link || event?.outlook_web_link || "";
                  return (
                    <tr key={`${row.kind}-${row.ref_id}-${row.at}`}>
                      <td style={{ width: 110, verticalAlign: "top" }}>
                        <span className="chip">{row.kind}</span>
                      </td>
                      <td>
                        <Link href={hrefFor(clientId, row)} style={{ fontWeight: 600 }}>
                          {row.title}
                        </Link>
                        {row.detail && (
                          <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)", marginTop: 2 }}>
                            {row.detail.length > 240 ? row.detail.slice(0, 240) + "…" : row.detail}
                          </div>
                        )}
                        {row.who && <div className="lock">{row.who}</div>}
                      </td>
                      <td style={{ textAlign: "right", whiteSpace: "nowrap", verticalAlign: "top" }}>
                        {/* A text answered from the feed rather than from a
                            second screen: the reply box is one tap away, with
                            the consent and hours rules where they already are. */}
                        {row.kind === "Text" && (
                          <Link
                            className="btn ghost"
                            href={`/clients/${clientId}?tab=messages`}
                            style={{ textDecoration: "none", padding: "2px 10px" }}
                          >
                            Reply
                          </Link>
                        )}{" "}
                        {outlook && (
                          <a className="btn ghost" href={outlook} target="_blank" rel="noopener noreferrer">
                            Open in Outlook
                          </a>
                        )}{" "}
                        {mail && <ExcludeThread conversationId={mail.conversation_id} />}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ))}
        </div>
      )}
    </>
  );
}
