import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sweepAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";
import { sendEmail, emailConfigured } from "@/lib/email";
import { sendReferralNudge } from "@/lib/intake-mail";
import { INTAKE_MAILBOX } from "@/lib/intake-source";

/**
 * Chasing what has not arrived.
 *
 * Rules 6 and 7 of the Intake Automation Brief. The intake route handles what
 * comes in; this is the other half - a referral with no authorization after a
 * week, and an authorization about to run out with work still in it.
 *
 * Both rules are in the database (0184), which answers "what is owed today"
 * from what is on file. This route sends what they say to send, and the
 * difference between the two is the point:
 *
 *   Rule 6 emails the counselor, twice, on the seventh and the fourteenth day.
 *   After that it is a task and no more email, because a third identical
 *   message is nagging rather than chasing.
 *
 *   Rule 7 emails nobody. Margaret gets the task and the drafted request and
 *   sends it herself. A renewal is a conversation and the practice's side of it
 *   should not arrive automatically - that is the brief's decision and a good
 *   one.
 *
 * Daily rather than every quarter hour: both are about days passing.
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/chase
 */
export const dynamic = "force-dynamic";
export const maxDuration = 300;

type Supabase = ReturnType<typeof createAdminClient>;

type Waiting = {
  client_id: string;
  client_name: string;
  counselor_name: string;
  counselor_email: string;
  received_on: string;
  days_waiting: number;
  nth: number;
  send: boolean;
  body: string;
};

type Ending = {
  auth_id: string;
  client_id: string;
  client_name: string;
  auth_number: string;
  service_type: string;
  end_date: string;
  days_left: number;
  hours_left: number | null;
  counselor_name: string;
  counselor_email: string;
  body: string;
};

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

  // Reads everything and sends nothing, so "what would go out today" is a
  // question anybody holding the secret can ask before it does.
  const dry = request.nextUrl.searchParams.get("dry") === "1";

  const admin = createAdminClient();
  const { data: settings } = await admin
    .from("org_settings")
    .select("intake_staff_id, billing_notify_staff_id")
    .limit(1)
    .maybeSingle();

  const nudged: Record<string, unknown>[] = [];
  const chased: Record<string, unknown>[] = [];
  const emailed: string[] = [];

  // ── Rule 6: a referral with no authorization ──────────────
  const { data: waitingRows, error: waitingError } = await admin.rpc(
    "referrals_without_authorization",
    {},
  );
  if (waitingError) {
    return NextResponse.json({ error: waitingError.message }, { status: 500 });
  }
  const waiting = (waitingRows ?? []) as unknown as Waiting[];

  let token: string | null = null;
  if (!dry && waiting.some((w) => w.send)) {
    token = await serviceToken(admin);
    if (!token) {
      return NextResponse.json(
        { error: `Nobody is connected to send as ${INTAKE_MAILBOX}, so no nudge was sent.` },
        { status: 503 },
      );
    }
  }

  const margaret = settings?.intake_staff_id ?? null;
  const { data: intakeStaff } = margaret
    ? await admin.from("staff").select("email").eq("id", margaret).maybeSingle()
    : { data: null };

  for (const w of waiting) {
    // The task goes up whether or not an email does, which is what "after
    // that, task only" means.
    const { data: told } = await admin.rpc("notify_person", {
      p_staff: margaret,
      p_kind: "authorization_missing",
      p_text: `${w.client_name} was referred ${w.days_waiting} days ago and still has no authorization.`,
      p_ref: `${w.client_id}:${w.nth}`,
      p_href: `/clients/${w.client_id}`,
      p_client: w.client_id,
      p_task_title: `Chase the authorization for ${w.client_name}`,
      p_due: null,
      p_level: w.days_waiting >= 14 ? "bad" : "warn",
      p_source: null,
    });

    let sent = false;
    if (w.send && !dry && token) {
      // Claimed before it is sent: record_referral_nudge returns false if it
      // has already gone, so a second run in a day sends nothing.
      // The body is not recorded with it: nothing in this system stores a
      // message body (verify_mail.sql), and these words are built from a
      // template in the database and can be read there.
      const { data: claimed } = await admin.rpc("record_referral_nudge", {
        p_client: w.client_id,
        p_nth: w.nth,
        p_to: w.counselor_email,
      });
      if (claimed) {
        await sendReferralNudge(
          token,
          w.counselor_email,
          intakeStaff?.email ? [intakeStaff.email] : [],
          `${w.client_name} — authorization`,
          w.body,
        );
        sent = true;
        emailed.push(w.counselor_email);
      }
    }

    for (const who of (told ?? []) as { email: string | null; message: string }[]) {
      if (!who.email || !emailConfigured()) continue;
      await sendEmail({ to: who.email, subject: "Zion CRM — chasing", text: who.message });
    }

    nudged.push({
      client: w.client_name,
      days: w.days_waiting,
      nth: w.nth,
      would_send: w.send,
      sent,
      to: w.counselor_email || "(no counselor address on file)",
    });
  }

  // ── Rule 7: an authorization about to run out ─────────────
  const { data: endingRows, error: endingError } = await admin.rpc(
    "authorizations_ending_soon",
    {},
  );
  if (endingError) {
    return NextResponse.json({ error: endingError.message }, { status: 500 });
  }
  const ending = (endingRows ?? []) as unknown as Ending[];

  for (const e of ending) {
    // One per authorization, and nothing is emailed to the counselor: the
    // draft rides along in the notification for Margaret to send.
    const text =
      `${e.client_name}'s authorization ${e.auth_number || "(no number)"} for ${e.service_type}` +
      ` ends ${e.end_date} (${e.days_left} days). Ask for a renewal.\n\nDraft:\n${e.body}`;

    for (const staffId of [settings?.intake_staff_id, settings?.billing_notify_staff_id]) {
      if (!staffId) continue;
      const { data: told } = await admin.rpc("notify_person", {
        p_staff: staffId,
        p_kind: "authorization_ending",
        p_text: text,
        p_ref: `${e.auth_id}:${staffId}`,
        p_href: `/billing/authorizations/${e.auth_id}`,
        p_client: e.client_id,
        p_task_title: `Request a renewal for ${e.client_name} — ${e.service_type}`,
        p_due: null,
        p_level: "warn",
        p_source: null,
      });
      for (const who of (told ?? []) as { email: string | null; message: string }[]) {
        if (!who.email || !emailConfigured() || dry) continue;
        await sendEmail({ to: who.email, subject: "Zion CRM — renewal needed", text: who.message });
      }
    }

    chased.push({
      client: e.client_name,
      authorization: e.auth_number,
      ends: e.end_date,
      days_left: e.days_left,
      hours_left: e.hours_left,
      counselor: e.counselor_email || "(no counselor address on file)",
    });
  }

  return NextResponse.json({
    dry,
    rule6: { waiting: waiting.length, would_send: waiting.filter((w) => w.send).length, nudged },
    rule7: { ending: ending.length, chased },
    emailed,
  });
}
