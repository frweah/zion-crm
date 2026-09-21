import Link from "next/link";
import { can, ROLE_LABEL } from "@/lib/roles";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { refreshAlertsIfStale, getAlerts } from "@/lib/alerts";
import { today, CAN_LOG_HOURS, money } from "@/lib/constants";
import { myMailAccess } from "@/lib/mail-access";
import { listCalendar, type CalendarItem } from "@/lib/calendar-view";
import { clientNoFromSubject } from "@/lib/graph";
import { practiceWallToDate, dateToPracticeWall } from "@/lib/practice-time";
import { DashboardTask } from "./dashboard-task";
import { MicrosoftCard } from "./microsoft-card";
import { WorkTimer } from "../hours/work-timer";
import { NEEDS, countNeeds } from "@/lib/needs";
import { PageHead } from "../page-head";
import { mailWaiting } from "../inbox-mail";
import { markConversationRead, snoozeAlert } from "./day-actions";

/**
 * The dashboard: the person's day, top to bottom (owner, 21 Sept 2026).
 *
 *   The work session, started and ended here, with today's total.
 *   What is waiting for their reply - texts, chat and mail - oldest first.
 *   Their tasks due today and overdue.
 *   Today's appointments.
 *   Their clients with something due today.
 *   The alerts.
 *   And for Admin, below the day, the business counters.
 *
 * Every line carries its action beside it, so most of a morning's small
 * things are done from here without opening the screen behind them. Each list
 * says so, quietly, when it has nothing in it.
 */
type Due = { kind: string; title: string; detail: string; href: string; urgency: number };

const hm = (wall: string) => {
  const [h, m] = wall.slice(11, 16).split(":").map(Number);
  return `${((h + 11) % 12) + 1}:${String(m).padStart(2, "0")} ${h < 12 ? "am" : "pm"}`;
};
const ago = (iso: string) => {
  const mins = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60000));
  if (mins < 60) return `${mins} min`;
  const hours = Math.round(mins / 60);
  if (hours < 48) return `${hours} h`;
  return `${Math.round(hours / 24)} days`;
};

export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ microsoft?: string; detail?: string }>;
}) {
  const me = await requireStaff();
  const supabase = await createClient();
  const day = today();
  const logsHours = CAN_LOG_HOURS.includes(me.role) || can(me, "billing", "edit");
  const hasCaseload = ["Admin", "Job Search", "Reports"].includes(me.role);
  const isAdmin = me.role === "Admin";

  const dayStart = practiceWallToDate(`${day}T00:00`)!;
  const dayEnd = new Date(dayStart.getTime() + 86400000);

  const [
    alerts,
    runResult,
    clientsResult,
    categoriesResult,
    checklistResult,
    msConnectionResult,
    msStateResult,
    timerResult,
    summaryResult,
    chatUnread,
    outside,
    mail,
    tasksResult,
    eventsResult,
    snoozesResult,
    access,
  ] = await Promise.all([
    getAlerts(),
    supabase.from("job_runs").select("last_run_at").eq("job", "notifications").maybeSingle(),
    supabase.from("clients").select("id, name, client_no, status, assigned_staff_id, stage").order("name"),
    supabase.from("work_categories").select("key, label").eq("active", true).order("sort_order"),
    supabase
      .from("staff_checklist")
      .select("task_id, label, detail, auto_key, auto_done, done_on, required, phase")
      .eq("staff_id", me.id)
      .eq("phase", "Onboarding")
      .eq("required", true)
      .order("sort_order"),
    supabase
      .from("microsoft_connections")
      .select("microsoft_email, display_name, connected_at, last_error, scopes")
      .eq("staff_id", me.id)
      .maybeSingle(),
    supabase.from("microsoft_sync_state").select("last_run_at, mail_logged, events_pulled, last_error").eq("staff_id", me.id).maybeSingle(),
    supabase.from("work_session_timers").select("started_at").maybeSingle(),
    supabase.from("my_hours_summary").select("today_hours").maybeSingle(),
    supabase.rpc("my_unread"),
    supabase.rpc("message_inbox", { p_show: "open" }),
    mailWaiting(5),
    // My tasks: due today or before, open. Everybody's are on Dashboard → Tasks.
    supabase
      .from("tasks")
      .select("id, title, due, client_id")
      .eq("assigned_staff_id", me.id)
      .eq("status", "Open")
      .lte("due", day)
      .order("due"),
    supabase
      .from("calendar_events")
      .select("id, client_id, kind, title, starts_at, ends_at, location, outlook_event_id")
      .eq("staff_id", me.id)
      .gte("starts_at", dayStart.toISOString())
      .lt("starts_at", dayEnd.toISOString()),
    supabase.from("staff_alert_snoozes").select("notification_id, until").gte("until", day),
    myMailAccess(),
  ]);

  refreshAlertsIfStale(runResult.data?.last_run_at);

  const clients = clientsResult.data ?? [];
  const clientById = new Map(clients.map((c) => [c.id, c]));
  const clientByNo = new Map(clients.filter((c) => c.client_no !== null).map((c) => [Number(c.client_no), c]));

  // ── waiting for a reply ─────────────────────────────────────
  const isId = (v: string | null | undefined): v is string => typeof v === "string" && v.length > 0;
  const chatIds = (chatUnread.data ?? []).filter((r) => (r.unread ?? 0) > 0).map((r) => r.conversation_id).filter(isId);
  const outsideRows = (outside.data ?? [])
    .filter((r) => (r.unread ?? 0) > 0 && (isAdmin || !r.assigned_staff_id || r.assigned_staff_id === me.id))
    .flatMap((r) => (isId(r.conversation_id) ? [{ ...r, conversation_id: r.conversation_id }] : []));
  const convIds = [...chatIds, ...outsideRows.map((r) => r.conversation_id)];
  const { data: convs } = convIds.length
    ? await supabase.from("conversations").select("id, title, last_seq, last_message_at").in("id", convIds)
    : { data: [] as { id: string; title: string; last_seq: number; last_message_at: string | null }[] };
  const convById = new Map((convs ?? []).map((c) => [c.id, c]));
  const { data: lastChat } = chatIds.length
    ? await supabase
        .from("messages")
        .select("conversation_id, seq, sender_label, body")
        .in("conversation_id", chatIds)
        .is("removed_at", null)
        .order("seq", { ascending: false })
        .limit(chatIds.length * 3)
    : { data: [] as { conversation_id: string; seq: number; sender_label: string; body: string }[] };
  const latestChat = new Map<string, { sender_label: string; body: string }>();
  for (const m of lastChat ?? []) if (!latestChat.has(m.conversation_id)) latestChat.set(m.conversation_id, m);

  type Waiting = {
    key: string;
    kind: "Text" | "Website" | "Chat" | "Mail";
    who: string;
    what: string;
    since: string;
    open: string;
    openLabel: string;
    read?: { conversationId: string; seq: number };
  };
  const waiting: Waiting[] = [
    ...chatIds.map((id) => {
      const c = convById.get(id);
      const last = latestChat.get(id);
      return {
        key: `chat-${id}`,
        kind: "Chat" as const,
        who: last?.sender_label || c?.title || "A colleague",
        what: (last?.body ?? "").slice(0, 120),
        since: c?.last_message_at ?? new Date().toISOString(),
        open: `/messages?c=${id}`,
        openLabel: "Reply",
        read: c ? { conversationId: id, seq: c.last_seq } : undefined,
      };
    }),
    ...outsideRows.map((r) => {
      const c = convById.get(r.conversation_id);
      const web = r.kind === "web";
      return {
        key: `${r.kind}-${r.conversation_id}`,
        kind: web ? ("Website" as const) : ("Text" as const),
        who: r.client_name || r.who || (web ? "A visitor" : "Unknown number"),
        what: (r.last_body ?? "").slice(0, 120),
        since: r.last_message_at ?? new Date().toISOString(),
        // A text is answered on the client's record, where consent and the
        // sending hours are checked; a website chat where it arrives.
        open: web || !r.client_id ? `/messages/texts?tab=${web ? "web" : "texts"}&c=${r.conversation_id}` : `/clients/${r.client_id}?tab=messages`,
        openLabel: "Reply",
        read: c ? { conversationId: r.conversation_id, seq: c.last_seq } : undefined,
      };
    }),
    ...(mail.connected
      ? mail.oldest.map((m) => ({
          key: `mail-${m.id}`,
          kind: "Mail" as const,
          who: m.from || "(no sender)",
          what: m.subject,
          since: m.receivedAt,
          open: `/mail?id=${encodeURIComponent(m.id)}`,
          openLabel: "Open",
        }))
      : []),
  ].sort((a, b) => a.since.localeCompare(b.since));
  const mailMore = mail.connected ? Math.max(0, mail.count - mail.oldest.length) : 0;

  // ── today's appointments ────────────────────────────────────
  const rows = eventsResult.data ?? [];
  const outlook: CalendarItem[] = access.ok
    ? await listCalendar(access.token, dayStart, dayEnd).catch(() => [] as CalendarItem[])
    : [];
  const rowByOutlook = new Map(rows.filter((r) => r.outlook_event_id).map((r) => [r.outlook_event_id!, r]));
  const seen = new Set<string>();
  const appointments = outlook
    .filter((e) => !e.isCancelled)
    .map((e) => {
      const row = rowByOutlook.get(e.id);
      if (row) seen.add(row.id);
      const tagged = clientNoFromSubject(e.subject);
      const clientId = row?.client_id ?? (tagged !== null ? (clientByNo.get(tagged)?.id ?? null) : null);
      return { key: e.id, title: e.subject, start: e.start, end: e.end, allDay: e.isAllDay, location: e.location, clientId, webLink: e.webLink };
    });
  for (const r of rows) {
    if (seen.has(r.id) || (r.outlook_event_id && outlook.length > 0)) continue;
    appointments.push({
      key: r.id,
      title: r.title,
      start: dateToPracticeWall(new Date(r.starts_at)) + ":00",
      end: dateToPracticeWall(new Date(r.ends_at)) + ":00",
      allDay: false,
      location: r.location,
      clientId: r.client_id,
      webLink: "",
    });
  }
  appointments.sort((a, b) => a.start.localeCompare(b.start));
  const nowWall = dateToPracticeWall(new Date());

  // ── my clients today ────────────────────────────────────────
  const mine = hasCaseload ? clients.filter((c) => c.status === "Active" && c.assigned_staff_id === me.id) : [];
  const due = await Promise.all(
    mine.map(async (c) => {
      const { data } = await supabase.rpc("client_next_actions", { p_client: c.id });
      return { client: c, items: (data ?? []) as Due[] };
    }),
  );
  const clientsDue = due
    .filter((d) => d.items.length > 0)
    .sort((a, b) => (a.items[0]?.urgency ?? 9) - (b.items[0]?.urgency ?? 9));

  // ── alerts, less the ones put aside ─────────────────────────
  const snoozed = new Set((snoozesResult.data ?? []).map((s) => s.notification_id));
  const shownAlerts = alerts.filter((a) => !snoozed.has(a.id));

  // ── Admin's business counters ───────────────────────────────
  let business: { needs: Record<string, number>; unbilled: number; outstanding: number; receivedMonth: number } | null = null;
  if (isAdmin) {
    const [needs, { data: econ }, { data: paid }] = await Promise.all([
      countNeeds(supabase, me),
      supabase.from("authorization_economics").select("status, unbilled, outstanding"),
      supabase.from("invoices").select("amount").eq("status", "Paid").gte("paid_date", `${day.slice(0, 7)}-01`),
    ]);
    const n = (v: unknown) => Number(v ?? 0);
    business = {
      needs,
      unbilled: (econ ?? []).filter((e) => e.status === "Open").reduce((s, e) => s + n(e.unbilled), 0),
      outstanding: (econ ?? []).reduce((s, e) => s + n(e.outstanding), 0),
      receivedMonth: (paid ?? []).reduce((s, i) => s + n(i.amount), 0),
    };
  }

  const msParams = await searchParams;
  const outstandingSetup = (checklistResult.data ?? []).filter((r) => !(r.auto_key ? r.auto_done === true : r.done_on !== null));
  const connection = msConnectionResult.data;
  const msState = msStateResult.data;
  const microsoft = (
    <MicrosoftCard
      connection={connection}
      notice={msParams.microsoft ?? null}
      detail={msParams.detail ?? null}
      lastRun={msState?.last_run_at ?? null}
      lastResult={msState ? { mail_logged: msState.mail_logged, events_pulled: msState.events_pulled, last_error: msState.last_error } : null}
    />
  );
  // Outlook that needs somebody's hand goes to the top; one that is working
  // sits at the foot of the page, out of the day's way.
  const microsoftNeedsAction = !connection || Boolean(connection.last_error) || Boolean(msParams.microsoft);
  const tasks = tasksResult.data ?? [];

  return (
    <>
      <PageHead title="Today" context={`${ROLE_LABEL[me.role]} · ${me.name}`} />

      {microsoftNeedsAction && microsoft}

      {outstandingSetup.length > 0 && (
        <div className="card day-section">
          <h3>Still to do before you are fully set up</h3>
          <ul style={{ margin: "8px 0 0", paddingLeft: 18 }}>
            {outstandingSetup.map((r) => (
              <li key={r.task_id} style={{ fontSize: "var(--text-md)", marginBottom: 4 }}>
                {r.label}
                {r.detail && <div className="lock">{r.detail}</div>}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* ── the work session ─────────────────────────────────── */}
      {logsHours && (
        <section className="day-section" aria-labelledby="day-work">
          <h2 className="h2" id="day-work">
            Work session <span className="day-total">{Number(summaryResult.data?.today_hours ?? 0).toFixed(2)} h today</span>
          </h2>
          <WorkTimer running={timerResult.data ?? null} clients={clients.filter((c) => c.status === "Active")} categories={categoriesResult.data ?? []} today={day} />
        </section>
      )}

      {/* ── waiting for a reply ──────────────────────────────── */}
      <section className="card day-section" aria-labelledby="day-replies">
        <h2 className="h2" id="day-replies">
          Waiting for your reply {waiting.length > 0 && <span className="chip warn">{waiting.length + mailMore}</span>}
        </h2>
        {waiting.length === 0 ? (
          <p className="empty">
            Nothing is waiting for you: no unread text, chat or website message{mail.connected ? ", and no unread mail" : ""}.
            {!mail.connected && " Connect Outlook to see your mail here too."}
          </p>
        ) : (
          <ul className="day-list">
            {waiting.map((w) => (
              <li key={w.key}>
                <span className="chip">{w.kind}</span>
                <span className="day-main">
                  <b>{w.who}</b>
                  {w.what && <span className="lock"> {w.what}</span>}
                </span>
                <span className="lock day-when">{ago(w.since)}</span>
                <span className="day-actions">
                  <Link className="btn ghost" href={w.open}>
                    {w.openLabel}
                  </Link>
                  {w.read && (
                    <form action={markConversationRead}>
                      <input type="hidden" name="conversation_id" value={w.read.conversationId} />
                      <input type="hidden" name="seq" value={w.read.seq} />
                      <button className="btn ghost" type="submit">
                        Mark read
                      </button>
                    </form>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}
        {mailMore > 0 && (
          <p className="lock" style={{ margin: "8px 0 0" }}>
            And {mailMore} more unread in <Link href="/mail">Inbox → Mail</Link>.
          </p>
        )}
      </section>

      {/* ── tasks ────────────────────────────────────────────── */}
      <section className="card day-section" aria-labelledby="day-tasks">
        <h2 className="h2" id="day-tasks">
          Your tasks due today or overdue
        </h2>
        {tasks.length === 0 ? (
          <p className="empty">
            Nothing due today and nothing overdue. Everything later is on{" "}
            {hasCaseload ? <Link href="/tasks">Dashboard → Tasks</Link> : "your clients' records"}.
          </p>
        ) : (
          tasks.slice(0, 12).map((t) => (
            <DashboardTask key={t.id} id={t.id} title={t.title} due={t.due} clientId={t.client_id} overdue={Boolean(t.due && t.due < day)} />
          ))
        )}
        {tasks.length > 12 && (
          <p className="lock" style={{ margin: "8px 0 0" }}>
            <Link href="/dashboard/needs?list=tasks">{tasks.length - 12} more</Link>
          </p>
        )}
      </section>

      {/* ── today's appointments ─────────────────────────────── */}
      <section className="card day-section" aria-labelledby="day-appts">
        <h2 className="h2" id="day-appts">
          Today&apos;s appointments
        </h2>
        {appointments.length === 0 ? (
          <p className="empty">
            Nothing on your calendar today{access.ok ? "" : " in the CRM - connect Outlook to see your whole day"}.
          </p>
        ) : (
          <ul className="day-list">
            {appointments.map((a) => {
              const client = a.clientId ? clientById.get(a.clientId) : null;
              const over = a.end <= nowWall;
              return (
                <li key={a.key} className={over ? "day-past" : undefined}>
                  <span className="day-when" style={{ minWidth: 72 }}>
                    {a.allDay ? "All day" : hm(a.start)}
                  </span>
                  <span className="day-main">
                    <b>{a.title}</b>
                    {a.location && <span className="lock"> · {a.location}</span>}
                  </span>
                  <span className="day-actions">
                    {client && (
                      <Link className="btn ghost" href={`/clients/${client.id}`}>
                        {client.name}
                      </Link>
                    )}
                    {client && over && (
                      <Link className="btn ghost" href={`/clients/${client.id}?tab=billing`}>
                        Log hours
                      </Link>
                    )}
                    {a.webLink && (
                      <a className="btn ghost" href={a.webLink} target="_blank" rel="noopener noreferrer">
                        Outlook
                      </a>
                    )}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
      </section>

      {/* ── my clients today ─────────────────────────────────── */}
      {hasCaseload && (
        <section className="card day-section" aria-labelledby="day-clients">
          <h2 className="h2" id="day-clients">
            Your clients today
          </h2>
          {clientsDue.length === 0 ? (
            <p className="empty">
              {mine.length === 0
                ? "No active clients are assigned to you."
                : `None of your ${mine.length} clients has anything due: no appointment booked, no form holding up billing, nothing unanswered.`}
            </p>
          ) : (
            <ul className="day-list">
              {clientsDue.slice(0, 10).map(({ client, items }) => (
                <li key={client.id}>
                  <span className="day-main">
                    <Link href={`/clients/${client.id}`}>
                      <b>{client.name}</b>
                    </Link>
                    <span className="lock"> {client.stage}</span>
                  </span>
                  <span className="day-actions">
                    {items.slice(0, 2).map((item, i) => (
                      <Link key={`${item.kind}-${i}`} className={"btn ghost" + (item.urgency <= 1 ? " day-soon" : "")} href={item.href} title={item.detail}>
                        {item.title}
                      </Link>
                    ))}
                  </span>
                </li>
              ))}
            </ul>
          )}
          {clientsDue.length > 10 && (
            <p className="lock" style={{ margin: "8px 0 0" }}>
              <Link href="/my-clients">All of them on Clients → My clients today</Link>
            </p>
          )}
        </section>
      )}

      {/* ── alerts ───────────────────────────────────────────── */}
      <section className="card day-section" aria-labelledby="day-alerts">
        <h2 className="h2" id="day-alerts">
          Alerts
        </h2>
        {shownAlerts.length === 0 ? (
          <p className="empty">
            No alerts{snoozed.size > 0 ? ` - ${snoozed.size} put aside until tomorrow` : ""}: no authorization short of hours or expiring, no
            invoice overdue, no counselor follow-up due.
          </p>
        ) : (
          <ul className="day-list">
            {shownAlerts.map((a) => (
              <li key={a.id}>
                <span className={"chip " + (a.level === "bad" ? "bad" : "warn")}>{a.level === "bad" ? "Now" : "Soon"}</span>
                <span className="day-main">{a.text}</span>
                <span className="day-actions">
                  {a.href && (
                    <Link className="btn ghost" href={a.href}>
                      Open
                    </Link>
                  )}
                  <form action={snoozeAlert}>
                    <input type="hidden" name="notification_id" value={a.id} />
                    <button className="btn ghost" type="submit" title="Out of your way until tomorrow. Nobody else's dashboard changes.">
                      Hide until tomorrow
                    </button>
                  </form>
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* ── Admin: the business ──────────────────────────────── */}
      {business && (
        <section className="day-section" aria-labelledby="day-business">
          <h2 className="h2" id="day-business">
            The business
          </h2>
          <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))" }}>
            {NEEDS.map((n) => (
              <Link key={n.key} href={`/dashboard/needs?list=${n.key}`} className="card" style={{ textDecoration: "none", color: "inherit" }}>
                <div className="stat" style={business!.needs[n.key] > 0 ? { color: "var(--bad)" } : undefined}>
                  {business!.needs[n.key]}
                  <small>{n.label.toLowerCase()}</small>
                </div>
              </Link>
            ))}
            <Link href="/insights/money#not-invoiced" className="card" style={{ textDecoration: "none", color: "inherit" }}>
              <div className="stat" style={business.unbilled > 0 ? { color: "var(--bad)" } : undefined}>
                {money(business.unbilled)}
                <small>earned, not invoiced</small>
              </div>
            </Link>
            <Link href="/insights/money" className="card" style={{ textDecoration: "none", color: "inherit" }}>
              <div className="stat">
                {money(business.outstanding)}
                <small>invoiced, not paid</small>
              </div>
            </Link>
            <Link href="/insights/money" className="card" style={{ textDecoration: "none", color: "inherit" }}>
              <div className="stat">
                {money(business.receivedMonth)}
                <small>received this month</small>
              </div>
            </Link>
          </div>
        </section>
      )}

      {!microsoftNeedsAction && microsoft}
    </>
  );
}
