import { phoneStaff, fresh } from "@/lib/phone/server";
import { today, PRACTICE_TZ } from "@/lib/constants";

/**
 * The phone's home: today, in four lines (owner, 11 Nov 2026).
 *
 * The next appointment, the clients to see, how many things are waiting to be
 * filed, and the reports due - for the person holding the phone, and nobody
 * else. Each is the same question My day asks, asked of the same tables, so
 * the phone and the desk cannot disagree about somebody's day.
 *
 * The phone keeps the answer, so the home still says something in a lift.
 * It also carries the To file items themselves (not only the count) and the
 * clock, because confirming a filing and clocking in are both things the
 * phone does with no signal.
 */
export const dynamic = "force-dynamic";

const dayOf = (iso: string) => new Date(iso).toLocaleDateString("en-CA", { timeZone: PRACTICE_TZ });

export async function GET() {
  const who = await phoneStaff();
  if ("response" in who) return who.response;
  const { staff: me, supabase } = who;
  const day = today();
  const now = new Date();
  const from = new Date(now.getTime() - 14 * 3_600_000).toISOString();
  const to = new Date(now.getTime() + 7 * 86_400_000).toISOString();

  const [events, mine, weeks, months, waiting, waitingCount, timer, hours] = await Promise.all([
    supabase
      .from("calendar_events")
      .select("id, client_id, kind, title, starts_at, location")
      .eq("staff_id", me.id)
      .gte("starts_at", from)
      .lte("starts_at", to)
      .order("starts_at")
      .limit(40),
    supabase
      .from("clients")
      .select("id, name")
      .or(`assigned_staff_id.eq.${me.id},billing_staff_id.eq.${me.id}`)
      .eq("status", "Active")
      .order("name")
      .limit(60),
    supabase
      .from("client_weekly_reports")
      .select("id, client_id, week_start, due_on")
      .eq("owner_id", me.id)
      .eq("status", "Draft")
      .order("due_on")
      .limit(30),
    supabase
      .from("client_reports")
      .select("id, client_id, period, status, due_on")
      .eq("owner_id", me.id)
      .neq("status", "Sent")
      .order("due_on")
      .limit(30),
    supabase
      .from("to_file")
      .select("id, source, title, detail, happened_at, client_id, guess_why, clients(name)")
      .eq("staff_id", me.id)
      .eq("state", "Waiting")
      .order("happened_at", { ascending: false, nullsFirst: false })
      .limit(30),
    supabase
      .from("to_file")
      .select("id", { count: "exact", head: true })
      .eq("staff_id", me.id)
      .eq("state", "Waiting"),
    supabase.from("work_session_timers").select("started_at, break_started_at, break_seconds").maybeSingle(),
    supabase.from("my_hours_summary").select("today_hours").maybeSingle(),
  ]);

  // A query that failed is not an empty day. Say so rather than draw one.
  const failed = [events, mine, weeks, months, waiting].find((r) => r.error);
  if (failed?.error) return fresh({ error: failed.error.message }, 503);

  const ids = [
    ...new Set([
      ...(weeks.data ?? []).map((w) => w.client_id),
      ...(months.data ?? []).map((m) => m.client_id),
      ...(events.data ?? []).map((e) => e.client_id).filter((x): x is string => Boolean(x)),
    ]),
  ];
  const mineIds = (mine.data ?? []).map((c) => c.id);
  const [names, nextUp] = await Promise.all([
    ids.length ? supabase.from("clients").select("id, name").in("id", ids) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    mineIds.length
      ? supabase.from("client_next_up").select("client_id, at, kind, title").in("client_id", mineIds)
      : Promise.resolve({ data: [] as { client_id: string | null; at: string | null; kind: string; title: string }[] }),
  ]);
  const nameOf = new Map<string, string>([
    ...(mine.data ?? []).map((c) => [c.id, c.name] as [string, string]),
    ...(names.data ?? []).map((c) => [c.id, c.name] as [string, string]),
  ]);

  const upcoming = (events.data ?? []).filter((e) => new Date(e.starts_at).getTime() >= now.getTime() - 15 * 60_000);
  const next = upcoming[0] ?? null;

  // Clients to see: an appointment with them today, or something due on them
  // by today. One line each, the appointment first because it has a time.
  const see = new Map<string, { id: string; name: string; why: string; at: string | null }>();
  for (const e of events.data ?? []) {
    if (!e.client_id || dayOf(e.starts_at) !== day) continue;
    if (!see.has(e.client_id)) {
      see.set(e.client_id, { id: e.client_id, name: nameOf.get(e.client_id) ?? "A client", why: e.title || e.kind, at: e.starts_at });
    }
  }
  for (const n of nextUp.data ?? []) {
    if (!n.client_id || see.has(n.client_id)) continue;
    if (n.at && n.at.slice(0, 10) > day) continue;
    see.set(n.client_id, { id: n.client_id, name: nameOf.get(n.client_id) ?? "A client", why: `${n.kind}: ${n.title}`, at: null });
  }

  const reports = [
    ...(weeks.data ?? []).map((w) => ({
      id: `week-${w.id}`,
      client_id: w.client_id,
      name: nameOf.get(w.client_id) ?? "A client",
      what: `Week of ${w.week_start}`,
      due: w.due_on,
      late: w.due_on < day,
    })),
    ...(months.data ?? []).map((m) => ({
      id: `month-${m.id}`,
      client_id: m.client_id,
      name: nameOf.get(m.client_id) ?? "A client",
      what: `${String(m.period).slice(0, 7)} — ${String(m.status).toLowerCase()}`,
      due: m.due_on,
      late: m.due_on < day,
    })),
  ].sort((a, b) => a.due.localeCompare(b.due));

  const toFile = ((waiting.data ?? []) as unknown as {
    id: string; source: string; title: string; detail: string; happened_at: string | null;
    client_id: string | null; guess_why: string; clients: { name: string } | null;
  }[]).map((f) => ({
    id: f.id,
    source: f.source,
    title: f.title,
    detail: f.detail,
    happened_at: f.happened_at,
    client_id: f.client_id,
    client_name: f.clients?.name ?? null,
    guess_why: f.guess_why,
  }));

  return fresh({
    staffId: me.id,
    name: me.name,
    role: me.role,
    day,
    asOf: now.toISOString(),
    next: next
      ? { title: next.title || next.kind, at: next.starts_at, where: next.location ?? "", client_id: next.client_id, client_name: next.client_id ? nameOf.get(next.client_id) ?? null : null }
      : null,
    see: [...see.values()].slice(0, 20),
    toFile,
    toFileCount: waitingCount.count ?? toFile.length,
    reports,
    clock: {
      startedAt: timer.data?.started_at ?? null,
      breakSince: timer.data?.break_started_at ?? null,
      breakSeconds: Number(timer.data?.break_seconds ?? 0),
      todayHours: Number(hours.data?.today_hours ?? 0),
    },
  });
}
