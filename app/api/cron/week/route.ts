import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sweepAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";
import { sendReferralNudge } from "@/lib/intake-mail";
import { INTAKE_MAILBOX } from "@/lib/intake-source";
import { today } from "@/lib/constants";
import { weekEmail, type Week } from "@/lib/week-report";

/**
 * Your week (item G of the owner's list).
 *
 * One email to each member of staff on a Friday afternoon, from service@,
 * about their own week: what they did, what is waiting on them now, and what
 * is already in next week's diary.
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/week
 *   …?dry=1      what it would send, sending nothing
 *   …?force=1    send it now, whatever day and hour it is
 *
 * **Friday is asked here and the hour is asked here**, the pattern the Monday
 * health run set: pg_cron thinks in UTC and Utah is UTC-6 half the year and
 * UTC-7 the other half, so a job fixed at one UTC hour drifts by an hour twice
 * a year. The job fires at 21:00 and 22:00 UTC on a Friday and this sends when
 * the hour in Utah is 15 - which is three in the afternoon in both halves of
 * the year, and once, because the other firing is not three o'clock there.
 *
 * One email each rather than one email with everybody in it. A week is a
 * person's own, and a list of five people's task counts in one message is a
 * thing nobody reads about themselves.
 *
 * Nothing in it is client data: counts, hours and dates. It can be read on a
 * phone in public without disclosing anybody, which is the same rule the
 * Monday email follows.
 */
export const dynamic = "force-dynamic";
export const maxDuration = 120;

type Supabase = ReturnType<typeof createAdminClient>;

/** The token that sends as service@, found the way the intake finds it. */
async function serviceToken(admin: Supabase) {
  const { data: shared } = await admin
    .from("shared_mailboxes")
    .select("connected_by")
    .ilike("address", INTAKE_MAILBOX)
    .eq("active", true)
    .maybeSingle();
  const { data: own } = await admin
    .from("microsoft_connections")
    .select("staff_id")
    .ilike("microsoft_email", INTAKE_MAILBOX)
    .maybeSingle();

  const staffId = shared?.connected_by ?? own?.staff_id ?? null;
  if (!staffId) return null;

  const { tokens } = sweepAccess(admin, staffId);
  const bundle = await tokens.read();
  if (!bundle) return null;
  return ensureFreshToken(bundle, tokens.write);
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

  // Reads everything and sends nothing, so "what would go out on Friday" is a
  // question anybody holding the secret can ask on a Tuesday.
  const dry = request.nextUrl.searchParams.get("dry") === "1";
  // And send it now, whatever day it is. Behind the secret like everything
  // else here, and never set by the schedule - the job posts with no query
  // string at all, so a forced send is always somebody asking for one.
  const forced = request.nextUrl.searchParams.get("force") === "1";

  const now = today();
  const isFriday = new Date(`${now}T00:00:00Z`).getUTCDay() === 5;
  // The hour in Utah, which is what makes this 15:00 Mountain all year.
  const hour = Number(
    new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Denver",
      hour: "numeric",
      hour12: false,
    }).format(new Date()),
  );

  const admin = createAdminClient();
  // One call for the whole practice. staff_week leaves out the check accounts
  // and anybody with no address, so this route has no roster of its own.
  const { data: rows, error } = await admin.rpc("staff_week", { p_today: now });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const weeks = ((rows ?? []) as unknown as Week[]).filter((w) => Boolean(w.email?.trim()));
  const letters = weeks.map((w) => ({ to: w.email, ...weekEmail(w, now) }));

  const due = (isFriday && hour === 15) || forced;

  if (dry || !due) {
    return NextResponse.json({
      dry,
      would_send: due,
      today: now,
      friday: isFriday,
      utah_hour: hour,
      letters,
    });
  }

  if (letters.length === 0) {
    return NextResponse.json(
      { error: "No active member of staff has an address, so there is nobody to write to." },
      { status: 503 },
    );
  }

  const token = await serviceToken(admin);
  if (!token) {
    return NextResponse.json(
      { error: `Nobody is connected to send as ${INTAKE_MAILBOX}, so no week email was sent.` },
      { status: 503 },
    );
  }

  /**
   * One at a time, and one failure does not stop the rest.
   *
   * A bad address or a Graph hiccup on the second of five people used to be
   * the whole sweep's problem in routes written this way. Each send is its own
   * answer in the result, so a run that half worked says which half.
   */
  const sent: string[] = [];
  const failed: { to: string; why: string }[] = [];
  for (const letter of letters) {
    try {
      await sendReferralNudge(token, letter.to, [], letter.subject, letter.body);
      sent.push(letter.to);
    } catch (err) {
      failed.push({ to: letter.to, why: err instanceof Error ? err.message : String(err) });
    }
  }

  return NextResponse.json({
    sent,
    failed,
    forced,
    today: now,
    utah_hour: hour,
  });
}
