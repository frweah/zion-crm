import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { myMailAccess } from "@/lib/mail-access";
import { listCalendar, type CalendarItem } from "@/lib/calendar-view";
import { clientNoFromSubject } from "@/lib/graph";
import { practiceWallToDate, dateToPracticeWall } from "@/lib/practice-time";
import { PageHead } from "../page-head";
import { EventForm } from "./event-form";
import { HoursOffer } from "../clients/[id]/calendar-tab";

/**
 * Calendar (Messaging brief, M).
 *
 * The signed-in person's Outlook calendar, a week or a day at a time, read
 * live. Appointments with a client - made here, or tagged [Client #N] in
 * Outlook - are marked with the client, in words as well as colour. A visit
 * that has finished offers to log the hours; it never logs them itself.
 */
const DAY = 86400000;
const iso = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (ymd: string, n: number) => iso(new Date(Date.parse(`${ymd}T00:00:00Z`) + n * DAY));
const weekday = (ymd: string) => new Date(`${ymd}T00:00:00Z`).getUTCDay(); // 0 Sunday
const dayLabel = (ymd: string) =>
  new Date(`${ymd}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });
const hm = (wall: string) => {
  const [h, m] = wall.slice(11, 16).split(":").map(Number);
  return `${((h + 11) % 12) + 1}:${String(m).padStart(2, "0")} ${h < 12 ? "am" : "pm"}`;
};

type Row = {
  id: string;
  client_id: string | null;
  kind: string;
  title: string;
  starts_at: string;
  ends_at: string;
  location: string;
  note: string;
  origin: string;
  outlook_event_id: string | null;
  push_state: string;
  hours_prompt_answered_at: string | null;
  staff_id: string;
};

type Item = CalendarItem & { row: Row | null; clientId: string | null; notInOutlook: boolean };

export default async function CalendarPage({
  searchParams,
}: {
  searchParams: Promise<{ view?: string; date?: string }>;
}) {
  const { view: rawView, date: rawDate } = await searchParams;
  const view = rawView === "day" ? "day" : "week";
  const date = /^\d{4}-\d{2}-\d{2}$/.test(rawDate ?? "") ? rawDate! : today();
  const first = view === "day" ? date : addDays(date, -((weekday(date) + 6) % 7)); // Monday
  const days = view === "day" ? [first] : Array.from({ length: 7 }, (_, i) => addDays(first, i));
  const from = practiceWallToDate(`${first}T00:00`)!;
  const to = practiceWallToDate(`${addDays(days[days.length - 1], 1)}T00:00`)!;

  const access = await myMailAccess();
  const supabase = await createClient();
  const me = access.me;

  const [calendar, { data: rows }, { data: clients }] = await Promise.all([
    access.ok
      ? listCalendar(access.token, from, to)
          .then((items) => ({ items, error: null as string | null }))
          .catch((e) => ({ items: [] as CalendarItem[], error: e instanceof Error ? e.message : "Outlook did not answer." }))
      : Promise.resolve({ items: [] as CalendarItem[], error: null as string | null }),
    me
      ? supabase
          .from("calendar_events")
          .select("id, client_id, kind, title, starts_at, ends_at, location, note, origin, outlook_event_id, push_state, hours_prompt_answered_at, staff_id")
          .eq("staff_id", me.id)
          .gte("starts_at", from.toISOString())
          .lt("starts_at", to.toISOString())
      : Promise.resolve({ data: [] as Row[] }),
    supabase.from("clients").select("id, name, client_no, status").order("name"),
  ]);

  const clientList = clients ?? [];
  const clientById = new Map(clientList.map((c) => [c.id, c]));
  const clientByNo = new Map(clientList.filter((c) => c.client_no !== null).map((c) => [Number(c.client_no), c]));
  const rowByOutlook = new Map(((rows ?? []) as Row[]).filter((r) => r.outlook_event_id).map((r) => [r.outlook_event_id!, r]));
  const seen = new Set<string>();

  const items: Item[] = calendar.items.map((e) => {
    const row = rowByOutlook.get(e.id) ?? null;
    if (row) seen.add(row.id);
    const tagged = clientNoFromSubject(e.subject);
    const clientId = row?.client_id ?? (tagged !== null ? (clientByNo.get(tagged)?.id ?? null) : null);
    return { ...e, row, clientId, notInOutlook: false };
  });
  // Saved here and not (yet) in Outlook: still shown, and said so.
  for (const r of (rows ?? []) as Row[]) {
    if (seen.has(r.id) || (r.outlook_event_id && calendar.items.length > 0)) continue;
    items.push({
      id: r.id,
      subject: r.title,
      start: dateToPracticeWall(new Date(r.starts_at)) + ":00",
      end: dateToPracticeWall(new Date(r.ends_at)) + ":00",
      isAllDay: false,
      location: r.location,
      webLink: "",
      showAs: "",
      isCancelled: false,
      row: r,
      clientId: r.client_id,
      notInOutlook: true,
    });
  }
  items.sort((a, b) => a.start.localeCompare(b.start));

  const now = new Date().toISOString();
  const pickable = clientList.filter((c) => c.status !== "Closed").map((c) => ({ id: c.id, name: c.name }));
  const link = (v: string, d: string) => `/calendar?view=${v}&date=${d}`;
  const step = view === "day" ? 1 : 7;

  return (
    <>
      <PageHead
        title="Calendar"
        context={
          access.ok
            ? view === "day"
              ? dayLabel(first)
              : `Week of ${dayLabel(first)}`
            : "Your Outlook calendar, inside the CRM"
        }
        actions={access.ok ? <EventForm draft={{ startsAt: `${date}T09:00` }} clients={pickable} label="New appointment" /> : undefined}
      />

      {!access.ok && (
        <div className="card" style={{ marginBottom: 14 }}>
          <p style={{ margin: 0 }}>{access.message}</p>
          <p style={{ margin: "12px 0 0" }}>
            <Link className="btn gold" href="/dashboard#outlook" style={{ textDecoration: "none" }}>
              Connect Outlook
            </Link>
          </p>
        </div>
      )}
      {calendar.error && <div className="alert bad">{calendar.error}</div>}

      <div className="row2 no-print" style={{ justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
        <div className="segmented" role="group" aria-label="Move through the calendar">
          <Link href={link(view, addDays(first, -step))}>← {view === "day" ? "Day before" : "Last week"}</Link>
          <Link href={link(view, today())}>Today</Link>
          <Link href={link(view, addDays(first, step))}>{view === "day" ? "Day after" : "Next week"} →</Link>
        </div>
        <div className="segmented" role="group" aria-label="View">
          <Link href={link("week", date)} className={view === "week" ? "on" : undefined}>
            Week
          </Link>
          <Link href={link("day", date)} className={view === "day" ? "on" : undefined}>
            Day
          </Link>
        </div>
      </div>

      <div className={view === "day" ? "cal-day" : "cal-week"}>
        {days.map((d) => {
          const todays = items.filter((e) => e.start.slice(0, 10) === d);
          return (
            <section key={d} className={"cal-col" + (d === today() ? " today" : "")} aria-label={dayLabel(d)}>
              <h3 className="cal-date">
                <Link href={link("day", d)}>{dayLabel(d)}</Link>
                {d === today() && <span className="chip gold">Today</span>}
              </h3>
              {todays.length === 0 ? (
                <p className="lock" style={{ margin: 0 }}>Nothing.</p>
              ) : (
                todays.map((e) => {
                  const client = e.clientId ? clientById.get(e.clientId) : null;
                  const r = e.row;
                  const finished = r && r.client_id && r.ends_at < now && r.staff_id === me?.id && !r.hours_prompt_answered_at;
                  const minutes = Math.max(5, Math.round((Date.parse(`${e.end}Z`) - Date.parse(`${e.start}Z`)) / 60000));
                  return (
                    <article key={e.id} className={"cal-event" + (client ? " client" : "") + (e.isCancelled ? " cancelled" : "")}>
                      <div className="lock">{e.isAllDay ? "All day" : `${hm(e.start)} – ${hm(e.end)}`}</div>
                      <b>{e.subject}</b>
                      {e.location && <div className="lock">{e.location}</div>}
                      <div className="cal-tags">
                        {client && (
                          <Link href={`/clients/${client.id}`} className="chip gold" style={{ textDecoration: "none" }}>
                            Client: {client.name}
                          </Link>
                        )}
                        {e.isCancelled && <span className="chip bad">Cancelled</span>}
                        {e.notInOutlook && <span className="chip warn">Not in Outlook yet</span>}
                        {r && r.kind && <span className="chip">{r.kind}</span>}
                      </div>
                      {finished && <HoursOffer event={r as never} clientId={r.client_id!} />}
                      {access.ok && !e.isCancelled && !e.isAllDay && (
                        <div style={{ marginTop: 6 }}>
                          <EventForm
                            label="Edit"
                            clients={pickable}
                            draft={{
                              crmId: r?.id,
                              outlookId: r ? undefined : e.id,
                              fromOutlook: !r || r.origin === "Outlook",
                              clientId: e.clientId,
                              kind: r?.kind,
                              title: r ? r.title : e.subject,
                              startsAt: e.start.slice(0, 16),
                              minutes,
                              location: e.location,
                              note: r?.note,
                            }}
                          />
                        </div>
                      )}
                    </article>
                  );
                })
              )}
            </section>
          );
        })}
      </div>
    </>
  );
}
