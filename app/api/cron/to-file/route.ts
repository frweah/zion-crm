import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sweepAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";
import { listCalendar } from "@/lib/calendar-view";
import { today } from "@/lib/constants";

/**
 * What the practice noticed and nobody has filed (item E).
 *
 * Two sweeps, nightly, both of which only ever *offer*:
 *
 *   **Mail** that names an active client and sits on no client's record. That
 *   is a question about rows the practice already has - the mail sweep writes
 *   one `mail_log` row per message, with its subject and no body - so it is a
 *   database function (0318) and no mailbox is opened for it.
 *
 *   **Calendar**: each staff member's own Outlook, read with their own token,
 *   for past events whose title, attendee or location names a client. Sixty
 *   days on the first look for that person, then two days, which is the
 *   owner's rule and also the only way a first run is not a sixty-day read
 *   every night.
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/to-file
 *   …?dry=1        what it would offer, offering nothing
 *   …?since=60     how many days back to look, for a deliberate first sweep
 *
 * **Nothing here reaches a client's record.** An offer is a row in one
 * person's inbox; confirming it is what writes the contact-log entry, and
 * confirming is something a person does on My day. The owner's words:
 * "never auto-file from here".
 *
 * Calendars.ReadWrite has been in the connection's scopes since the Calendar
 * screen was built, so nobody is prompted to consent again - the owner
 * expected a one-off prompt for Calendars.Read and it turns out the
 * permission was already there.
 */
export const dynamic = "force-dynamic";
export const maxDuration = 300;

type Supabase = ReturnType<typeof createAdminClient>;

/** Which clients a piece of text names, asked of the database. */
async function namedIn(admin: Supabase, text: string) {
  const { data } = await admin.rpc("clients_named_in", { p_text: text.slice(0, 2000) });
  return (data ?? []) as { client_id: string; how: string }[];
}

export async function POST(request: NextRequest) {
  return handle(request);
}

export async function GET(request: NextRequest) {
  return handle(request);
}

async function handle(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  const provided =
    request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ??
    request.nextUrl.searchParams.get("secret");
  if (!secret || provided !== secret) {
    return NextResponse.json({ error: "Not authorised." }, { status: 401 });
  }

  const dry = request.nextUrl.searchParams.get("dry") === "1";
  const asked = Number(request.nextUrl.searchParams.get("since") ?? "");
  const since = Number.isFinite(asked) && asked > 0 ? Math.min(asked, 400) : null;

  const admin = createAdminClient();
  const day = today();

  // ── mail ───────────────────────────────────────────────────
  let mailOffered = 0;
  let mailError: string | null = null;
  if (!dry) {
    const { data, error } = await admin.rpc("to_file_from_mail", {
      p_since: since ? isoDaysAgo(day, since) : null,
    });
    if (error) mailError = error.message;
    else mailOffered = Number(data ?? 0);
  }

  // ── calendars ──────────────────────────────────────────────
  //
  // Everybody with a Microsoft connection, each read with their own token.
  // There is no practice-wide calendar read and there should not be: a
  // person's diary is theirs, and what the CRM may see of it is what their
  // own connection allows.
  const { data: connected } = await admin
    .from("microsoft_connections")
    .select("staff_id, microsoft_email");

  const calendars: Record<string, unknown>[] = [];
  let calendarOffered = 0;

  for (const connection of connected ?? []) {
    const staffId = connection.staff_id;
    if (!staffId) continue;

    // The first look is sixty days; after that it is two, because the sweep
    // has seen everything older. "First look" is a question about this
    // person's inbox rather than a date kept somewhere: it is the first look
    // if nothing from their calendar has ever been offered.
    const { count } = await admin
      .from("to_file")
      .select("id", { count: "exact", head: true })
      .eq("staff_id", staffId)
      .eq("source", "Calendar");
    const days = since ?? (count && count > 0 ? 2 : 60);

    let token: string | null = null;
    try {
      const { tokens } = sweepAccess(admin, staffId);
      const bundle = await tokens.read();
      token = bundle ? await ensureFreshToken(bundle, tokens.write) : null;
    } catch {
      token = null;
    }
    if (!token) {
      calendars.push({ staff_id: staffId, days, read: 0, offered: 0, why: "no usable connection" });
      continue;
    }

    const from = new Date(`${isoDaysAgo(day, days)}T00:00:00Z`);
    const to = new Date();
    let events: Awaited<ReturnType<typeof listCalendar>> = [];
    try {
      events = await listCalendar(token, from, to);
    } catch (err) {
      calendars.push({
        staff_id: staffId,
        days,
        read: 0,
        offered: 0,
        why: err instanceof Error ? err.message : String(err),
      });
      continue;
    }

    let offered = 0;
    const matched: Record<string, unknown>[] = [];
    for (const event of events) {
      if (event.isCancelled) continue;
      // Past events only. An appointment that has not happened yet is not
      // something to confirm, and it is already on the calendar screen.
      if (event.end && new Date(`${event.end}Z`) > new Date()) continue;

      const text = [event.subject, event.attendees, event.location].filter(Boolean).join(" ");
      const named = await namedIn(admin, text);
      if (named.length === 0) continue;

      matched.push({
        subject: event.subject,
        start: event.start,
        client_id: named[0].client_id,
        how: named[0].how,
      });
      if (dry) continue;

      const { error } = await admin.rpc("to_file_offer", {
        p_staff: staffId,
        p_source: "Calendar",
        p_source_key: event.id,
        p_title: event.subject,
        p_detail: [event.location, event.attendees].filter(Boolean).join(" · ").slice(0, 400),
        p_happened: event.start ? `${event.start}Z` : null,
        p_client: named[0].client_id,
        p_guess_why: named[0].how,
      });
      if (!error) offered += 1;
    }

    calendarOffered += offered;
    calendars.push({ staff_id: staffId, days, read: events.length, offered, matched });
  }

  return NextResponse.json({
    dry,
    today: day,
    since_days: since,
    mail: { offered: mailOffered, error: mailError },
    calendar: { offered: calendarOffered, per_person: calendars },
  });
}

/** The day n days before this one, as a date. */
function isoDaysAgo(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString().slice(0, 10);
}
