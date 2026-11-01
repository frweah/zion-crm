import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sweepAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";
import { sendReferralNudge } from "@/lib/intake-mail";
import { INTAKE_MAILBOX } from "@/lib/intake-source";
import { today } from "@/lib/constants";
import { healthEmail, type Health } from "@/lib/health-report";

/**
 * The Monday health run (owner, 29 Oct 2026).
 *
 * One email, Monday morning, from service@ to Admin, with seven things in it:
 * the verification suite's result, the last backup fingerprint and its age,
 * the Graph subscriptions and when they expire, the stale filter's count,
 * billing older than ninety days, and the reports due, sent, overdue and
 * oldest unsent.
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/health
 *   …?dry=1    what it would send, sending nothing
 *
 * **Monday is asked here and the hour is asked here**, which is the pattern
 * every other job in this system follows: pg_cron thinks in UTC and Utah is
 * UTC-6 half the year and UTC-7 the other half, so a job fixed at one UTC hour
 * drifts by an hour twice a year. The job fires at 13:00 and 14:00 UTC and
 * this sends when the Utah hour is 7 - which is 07:00 Mountain in both halves
 * of the year, and once, because the other firing is not 7 o'clock there.
 *
 * It sends to every active Admin. Admin is the role that answers for the
 * practice, and a person leaving is then one row in the staff table rather
 * than a setting somebody has to remember to change.
 *
 * Nothing in the email is client data: counts, dates and a fingerprint. It can
 * be read on a phone without disclosing anybody.
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

  // Reads everything and sends nothing, so "what would go out on Monday" is a
  // question anybody holding the secret can ask on a Wednesday.
  const dry = request.nextUrl.searchParams.get("dry") === "1";

  const now = today();
  const isMonday = new Date(`${now}T00:00:00Z`).getUTCDay() === 1;
  // The hour in Utah, which is what makes this 07:00 Mountain all year.
  const hour = Number(
    new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Denver",
      hour: "numeric",
      hour12: false,
    }).format(new Date()),
  );

  const admin = createAdminClient();
  const { data: rows, error } = await admin.rpc("practice_health_summary");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const health = (Array.isArray(rows) ? rows[0] : rows) as unknown as Health;
  const { subject, body } = healthEmail(health, now);

  const { data: admins } = await admin
    .from("staff")
    .select("email")
    .eq("role", "Admin")
    .eq("active", true);
  const to = (admins ?? []).map((a) => a.email).filter((e): e is string => Boolean(e?.trim()));

  const due = isMonday && hour === 7;

  if (dry || !due) {
    return NextResponse.json({
      dry,
      would_send: due,
      today: now,
      monday: isMonday,
      utah_hour: hour,
      to,
      subject,
      body,
    });
  }

  if (to.length === 0) {
    return NextResponse.json(
      { error: "No active Admin has an address, so the health run has nobody to tell." },
      { status: 503 },
    );
  }

  const token = await serviceToken(admin);
  if (!token) {
    return NextResponse.json(
      { error: `Nobody is connected to send as ${INTAKE_MAILBOX}, so no health email was sent.` },
      { status: 503 },
    );
  }

  await sendReferralNudge(token, to[0], to.slice(1), subject, body);

  return NextResponse.json({ sent: true, today: now, utah_hour: hour, to, subject });
}
