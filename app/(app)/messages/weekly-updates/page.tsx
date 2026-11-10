import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PRACTICE_TZ } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DraftThisWeek, SendAllApproved, UpdateCard, type UpdateRow } from "./update-card";

/**
 * Weekly updates (part B, owner 9 November 2026).
 *
 * The drafts for one week, in one list: every active client and every contact
 * who receives them. Each is read, changed if it needs changing, approved,
 * and sent — and nothing goes without a click, which is the rule this screen
 * is shaped by.
 *
 * It is not a list of texts. The texts are in the thread on the client's
 * record, where every other text is; this is the half hour on a Friday
 * afternoon when somebody reads twenty of them.
 *
 * A row that cannot be sent says so with the reason before anybody clicks,
 * and the reason is about the number rather than the person: a client whose
 * own number has no consent may have a partner who has given it, and those
 * are two rows here with two different answers.
 */
export const dynamic = "force-dynamic";

const CAN_SEND = ["Admin", "Job Search", "Reports"];

/** The Monday of a week, from a date in it. */
function mondayOf(day: string): string {
  const d = new Date(`${day}T00:00:00Z`);
  const iso = d.getUTCDay() === 0 ? 7 : d.getUTCDay();
  d.setUTCDate(d.getUTCDate() - (iso - 1));
  return d.toISOString().slice(0, 10);
}

function shiftWeek(monday: string, weeks: number): string {
  const d = new Date(`${monday}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + weeks * 7);
  return d.toISOString().slice(0, 10);
}

const readable = (day: string) =>
  new Date(`${day}T00:00:00Z`).toLocaleDateString("en-GB", {
    timeZone: "UTC",
    day: "numeric",
    month: "long",
  });

export default async function WeeklyUpdatesPage({
  searchParams,
}: {
  searchParams: Promise<{ week?: string }>;
}) {
  const me = await requireStaff();
  const { week: asked } = await searchParams;

  const todayInUtah = new Intl.DateTimeFormat("en-CA", {
    timeZone: PRACTICE_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
  const week = /^\d{4}-\d{2}-\d{2}$/.test(asked ?? "") ? mondayOf(asked!) : mondayOf(todayInUtah);
  const canSend = CAN_SEND.includes(me.role);

  const supabase = await createClient();
  const [{ data: drafts }, { data: clients }, { data: contacts }, { data: consent }] =
    await Promise.all([
      supabase
        .from("weekly_updates")
        .select("id, client_id, contact_id, phone, language, body, state, reason, sent_at")
        .eq("week_start", week),
      supabase.from("clients").select("id, name"),
      supabase.from("client_contacts").select("id, name, relationship"),
      supabase.from("sms_consent_numbers").select("client_id, phone, state, can_text"),
    ]);

  const clientName = new Map((clients ?? []).map((c) => [c.id, c.name]));
  const contactOf = new Map((contacts ?? []).map((t) => [t.id, t]));
  const consentOf = new Map(
    ((consent ?? []) as { client_id: string; phone: string; state: string | null; can_text: boolean | null }[]).map(
      (n) => [`${n.client_id}:${n.phone}`, n],
    ),
  );

  const rows: UpdateRow[] = ((drafts ?? []) as Record<string, unknown>[])
    .map((d) => {
      const contact = d.contact_id ? contactOf.get(String(d.contact_id)) : undefined;
      const said = consentOf.get(`${String(d.client_id)}:${String(d.phone ?? "")}`);
      return {
        id: String(d.id),
        client_id: String(d.client_id),
        contact_id: (d.contact_id as string | null) ?? null,
        client_name: clientName.get(String(d.client_id)) ?? "",
        to_name: contact?.name ?? clientName.get(String(d.client_id)) ?? "",
        relationship: contact?.relationship ?? "",
        phone: (d.phone as string | null) ?? null,
        language: String(d.language ?? ""),
        body: String(d.body ?? ""),
        state: String(d.state ?? "Draft"),
        reason: String(d.reason ?? ""),
        consent: said?.state ?? null,
        can_text: Boolean(said?.can_text),
        sent_at: (d.sent_at as string | null) ?? null,
      };
    })
    .sort(
      (a, b) =>
        Number(b.state === "Draft") - Number(a.state === "Draft") ||
        a.client_name.localeCompare(b.client_name) ||
        Number(Boolean(a.contact_id)) - Number(Boolean(b.contact_id)),
    );

  const count = (state: string) => rows.filter((r) => r.state === state).length;
  const approved = count("Approved");

  return (
    <>
      <PageHead
        title="Weekly updates"
        context={`The week of ${readable(week)}, one text each`}
      />

      <div className="segmented" role="group" aria-label="Which week" style={{ marginBottom: 12 }}>
        <Link href={`/messages/weekly-updates?week=${shiftWeek(week, -1)}`}>Earlier</Link>
        <span className="on">{readable(week)}</span>
        <Link href={`/messages/weekly-updates?week=${shiftWeek(week, 1)}`}>Later</Link>
      </div>

      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))" }}>
        <div className="card">
          <div className="stat">
            {count("Draft")}
            <small>to read</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {approved}
            <small>approved, not sent</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {count("Sent")}
            <small>sent</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {count("Not sent")}
            <small>not sent</small>
          </div>
        </div>
      </div>

      <section className="page-section">
        {canSend && approved > 0 && <SendAllApproved week={week} approved={approved} />}
        {canSend && rows.length === 0 && <DraftThisWeek week={week} />}
        {rows.length === 0 ? (
          <p className="empty">
            Nothing drafted for this week — the drafts are made on Friday afternoon.
          </p>
        ) : (
          rows.map((row) => <UpdateCard key={row.id} row={row} canSend={canSend} />)
        )}
      </section>
    </>
  );
}
