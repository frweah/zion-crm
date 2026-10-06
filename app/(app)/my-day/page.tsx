import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today, fmtStamp } from "@/lib/constants";
import { PageHead } from "../page-head";

/**
 * My day (Design language, §3).
 *
 * One column, in time order: the appointments, the tasks due, and the clients
 * to see. The dashboard answers "what is waiting"; this answers "what is
 * today", which is a different question and the one somebody asks at nine in
 * the morning.
 *
 * Everything that has a time sits at its time. Everything that does not - a
 * task due today, a client nobody has spoken to in a fortnight - sits under
 * the day, because pretending it happens at nine o'clock would be inventing
 * a schedule nobody agreed to.
 */
type Row = {
  key: string;
  at: string | null;
  kind: string;
  what: string;
  detail: string;
  href: string;
  bad?: boolean;
};

export default async function MyDayPage() {
  const me = await requireStaff();
  const supabase = await createClient();
  const day = today();
  const dayStart = new Date(`${day}T00:00:00`);
  const dayEnd = new Date(`${day}T23:59:59`);

  const [{ data: events }, { data: tasks }, { data: due }] = await Promise.all([
    supabase
      .from("calendar_events")
      .select("id, client_id, kind, title, starts_at, ends_at, location")
      .eq("staff_id", me.id)
      .gte("starts_at", dayStart.toISOString())
      .lte("starts_at", dayEnd.toISOString())
      .order("starts_at"),
    supabase
      .from("tasks")
      .select("id, title, due, client_id")
      .eq("assigned_staff_id", me.id)
      .eq("status", "Open")
      .lte("due", day)
      .order("due"),
    // The clients this person works, and what is next on each. The view is
    // keyed by client, so whose clients they are is asked here.
    supabase
      .from("clients")
      .select("id, name")
      .or(`assigned_staff_id.eq.${me.id},billing_staff_id.eq.${me.id}`)
      .eq("status", "Active")
      .order("name")
      .limit(60),
  ]);

  const mineIds = (due ?? []).map((c) => c.id);
  const { data: nextUp } = mineIds.length
    ? await supabase.from("client_next_up").select("client_id, at, kind, title").in("client_id", mineIds)
    : { data: [] as { client_id: string; at: string | null; kind: string; title: string }[] };
  const nameOf = new Map((due ?? []).map((c) => [c.id, c.name] as const));

  const rows: Row[] = [];

  for (const e of events ?? []) {
    rows.push({
      key: `event-${e.id}`,
      at: e.starts_at,
      kind: e.kind ?? "Appointment",
      what: e.title ?? "Appointment",
      detail: e.location ?? "",
      href: e.client_id ? `/clients/${e.client_id}` : "/calendar",
    });
  }

  for (const t of tasks ?? []) {
    rows.push({
      key: `task-${t.id}`,
      at: null,
      kind: "Task",
      what: t.title,
      detail: t.due && t.due < day ? `overdue since ${t.due}` : "due today",
      href: t.client_id ? `/clients/${t.client_id}` : "/tasks",
      bad: Boolean(t.due && t.due < day),
    });
  }

  for (const c of nextUp ?? []) {
    // Only what is due by today; what is coming later is not today's list.
    if (c.at && c.at.slice(0, 10) > day) continue;
    rows.push({
      key: `next-${c.client_id}-${c.kind}-${c.title}`,
      at: null,
      kind: "Client",
      what: (c.client_id ? nameOf.get(c.client_id) : null) ?? "A client",
      detail: `${c.kind}: ${c.title}`,
      href: `/clients/${c.client_id ?? ""}`,
      bad: Boolean(c.at && c.at.slice(0, 10) < day),
    });
  }

  const timed = rows.filter((r) => r.at).sort((a, b) => (a.at ?? "").localeCompare(b.at ?? ""));
  const untimed = rows.filter((r) => !r.at);

  return (
    <>
      <PageHead
        title={`My day · ${new Date(`${day}T12:00:00`).toLocaleDateString("en-US", {
          weekday: "long",
          month: "long",
          day: "numeric",
        })}`}
        context={me.name}
      />

      {rows.length === 0 ? (
        <p className="empty">
          Nothing is scheduled and nothing is due. What is waiting for a reply is on{" "}
          <Link href="/dashboard">Home</Link>.
        </p>
      ) : (
        <>
          <section className="page-section">
            <h2 className="h2">At a time</h2>
            {timed.length === 0 ? (
              <p className="empty">Nothing on your calendar today.</p>
            ) : (
              <ul className="day-list">
                {timed.map((r) => (
                  <li key={r.key}>
                    <span className="chip">{r.kind}</span>
                    <span className="day-main">
                      <Link href={r.href}>
                        <b>{r.what}</b>
                      </Link>
                      {r.detail && <span className="lock"> {r.detail}</span>}
                    </span>
                    <span className="lock day-when">{fmtStamp(r.at as string)}</span>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section className="page-section">
            <h2 className="h2">Today, at no particular time</h2>
            {untimed.length === 0 ? (
              <p className="empty">Nothing else is due today.</p>
            ) : (
              <ul className="day-list">
                {untimed.map((r) => (
                  <li key={r.key}>
                    <span className={"chip" + (r.bad ? " warn" : "")}>{r.kind}</span>
                    <span className="day-main">
                      <Link href={r.href}>
                        <b>{r.what}</b>
                      </Link>
                      {r.detail && <span className="lock"> {r.detail}</span>}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </>
  );
}
