import { NextResponse, type NextRequest } from "next/server";
import { authorizationNumberLabel } from "@/lib/billing";
import { createAdminClient } from "@/lib/supabase/admin";
import { sweepAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";
import { sendEmail, emailConfigured } from "@/lib/email";
import { sendReferralNudge } from "@/lib/intake-mail";
import { INTAKE_MAILBOX } from "@/lib/intake-source";
import { NO_REPLY_DAYS, money } from "@/lib/constants";

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
      // The client this is about. Without it, notify_person's "have I raised
      // this already" lookup matched every open item of the kind that named
      // nothing, so the first client chased took the only row the kind was
      // allowed and nobody else was ever chased again (0282).
      p_source: w.client_id,
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
      `${e.client_name}'s ${e.service_type} authorization (${authorizationNumberLabel({ number: e.auth_number })})` +
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
        // The authorization that is ending. One renewal to ask for per
        // authorization, not one for the practice (0282).
        p_source: e.auth_id,
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

  // ── An application nobody has heard about ─────────────────
  // The owner's rule (30 Oct 2026): 'No response' after 14 days, overridable.
  // Here rather than in its own route because it is the same kind of rule as
  // the two above - a day passing is the whole event - and it belongs with
  // them for the same reason they belong together.
  //
  // It emails nobody and notifies nobody, which is deliberate: a notification
  // about something not happening, on every application that has gone quiet,
  // is how a notification list stops being read. The status shows on the
  // client's Job Search tab, which is where somebody is already looking.
  let noReply: number | null = null;
  if (!dry) {
    const { data, error } = await admin.rpc("mark_applications_with_no_reply", {
      p_days: NO_REPLY_DAYS,
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    noReply = (data ?? 0) as number;
  }

  /**
   * An invoice nobody has answered, and work nobody has invoiced (0309).
   *
   * Here rather than in a route of its own for the reason the application
   * rule is here: a day passing is the whole event, and these belong with the
   * other rules that are about days passing.
   *
   * Both rules are the database's, and both are deduplicated there: thirty
   * days raises it at the intake desk, forty-five reaches the owner, and
   * running this twice in a day sends nothing twice. What comes back is the
   * words for the email, one row per person who had something new.
   */
  let invoiceChase: { chased: number; emailed: number } = { chased: 0, emailed: 0 };
  let invoiceDue: { raised: number; emailed: number } = { raised: 0, emailed: 0 };

  if (!dry) {
    const { data: chaseRows, error: chaseError } = await admin.rpc("chase_invoices", {});
    if (chaseError) return NextResponse.json({ error: chaseError.message }, { status: 500 });
    const told = (chaseRows ?? []) as { email: string | null; message: string }[];
    invoiceChase.chased = told.length;
    for (const who of told) {
      if (!who.email || !emailConfigured()) continue;
      await sendEmail({ to: who.email, subject: "Zion CRM — an invoice is unpaid", text: who.message });
      invoiceChase.emailed += 1;
    }

    const { data: dueRows, error: dueError } = await admin.rpc("invoices_due", {});
    if (dueError) return NextResponse.json({ error: dueError.message }, { status: 500 });
    const toBill = (dueRows ?? []) as { email: string | null; message: string }[];
    invoiceDue.raised = toBill.length;
    for (const who of toBill) {
      if (!who.email || !emailConfigured()) continue;
      await sendEmail({ to: who.email, subject: "Zion CRM — an invoice is due", text: who.message });
      invoiceDue.emailed += 1;
    }
  }

  /**
   * Four things the owner asked for on 9 November 2026, each a question the
   * database answers rather than a task somebody typed once.
   *
   * The first three are one item each, addressed to the intake desk, carrying
   * the list. One item rather than one per row because they are one job of
   * data entry: a day spent with the paper invoices, a day with the paper 95s.
   *
   * The fourth is one item **per authorization**, addressed to whoever works
   * that client, and that is the owner's ruling rather than an accident: a
   * delivery date is something the person who did the work knows, and eight
   * of them on the intake desk is a list nobody can answer.
   */
  const owed = { numbers: 0, hours: 0, phones: 0, delivery: 0 };
  if (!dry) {
    const desk = settings?.intake_staff_id ?? null;

    // ── invoices whose number nobody has read ──────────────
    const { data: unnumbered, error: unnumberedError } = await admin.rpc("invoices_without_a_number", {});
    if (unnumberedError) return NextResponse.json({ error: unnumberedError.message }, { status: 500 });
    const noNumber = (unnumbered ?? []) as {
      invoice_id: string; client_name: string | null; auth_number: string | null; amount: number | null;
    }[];
    if (desk && noNumber.length) {
      owed.numbers = noNumber.length;
      const lines = noNumber
        .map((i) => `  ${i.client_name ?? "unknown client"} · ${i.auth_number || "no authorization"} · ${money(i.amount)}`)
        .join("\n");
      await admin.rpc("notify_person", {
        p_staff: desk,
        p_kind: "invoice_number_missing",
        p_text:
          `${noNumber.length} ${noNumber.length === 1 ? "invoice" : "invoices"} went to USOR before the CRM numbered them. ` +
          `The number on each is on your copy and nowhere here:\n\n${lines}`,
        p_ref: `desk:${noNumber.length}`,
        p_href: "/billing/invoices",
        p_task_title: `Put the invoice numbers on ${noNumber.length} ${noNumber.length === 1 ? "invoice" : "invoices"}`,
        p_level: "warn",
        // One item for the job, named by a constant: the whole-practice case
        // notify_person allows, because the thing it is about is the practice.
        p_source: "00000000-0000-0000-0000-000000000001",
      });
    }

    // ── hourly work whose hours are on paper ───────────────
    const { data: noHoursRows, error: noHoursError } = await admin.rpc("hourly_work_without_hours", {});
    if (noHoursError) return NextResponse.json({ error: noHoursError.message }, { status: 500 });
    const noHours = (noHoursRows ?? []) as {
      auth_id: string; client_name: string | null; number: string | null; service_type: string | null;
    }[];
    if (desk && noHours.length) {
      owed.hours = noHours.length;
      const lines = noHours
        .map((a) => `  ${a.client_name ?? "unknown client"} · ${authorizationNumberLabel({ number: a.number })} · ${a.service_type ?? ""}`)
        .join("\n");
      await admin.rpc("notify_person", {
        p_staff: desk,
        p_kind: "service_hours_from_paper",
        p_text:
          `${noHours.length} open hourly ${noHours.length === 1 ? "authorization has" : "authorizations have"} no hours logged. ` +
          `Until the hours are in, what the work comes to is a ceiling rather than a figure:\n\n${lines}`,
        p_ref: `desk:${noHours.length}`,
        p_href: "/billing?tab=hours",
        p_task_title: `Enter the hours from the paper 95s for ${noHours.length} ${noHours.length === 1 ? "authorization" : "authorizations"}`,
        p_level: "warn",
        p_source: "00000000-0000-0000-0000-000000000002",
      });
    }

    // ── a client nobody can ring ───────────────────────────
    const { data: noPhoneRows, error: noPhoneError } = await admin.rpc("clients_without_a_number", {});
    if (noPhoneError) return NextResponse.json({ error: noPhoneError.message }, { status: 500 });
    const noPhone = (noPhoneRows ?? []) as { client_id: string; client_name: string | null }[];
    for (const c of noPhone) {
      owed.phones += 1;
      if (!desk) break;
      await admin.rpc("notify_person", {
        p_staff: desk,
        p_kind: "client_has_no_phone",
        p_text:
          `${c.client_name ?? "A client"} has no phone number on their record, no reason for having none, ` +
          "and no contact who answers for them. Nothing can be texted to them and nobody can ring them.",
        p_ref: c.client_id,
        p_href: `/clients/${c.client_id}?tab=profile`,
        p_client: c.client_id,
        p_task_title: `Find a number for ${c.client_name ?? "a client"}, or say why there is none`,
        p_level: "warn",
        p_source: c.client_id,
      });
    }

    // ── work that may or may not be done ───────────────────
    const { data: waitingRows, error: waitingDeliveryError } = await admin.rpc(
      "authorizations_waiting_for_delivery",
      {},
    );
    if (waitingDeliveryError) {
      return NextResponse.json({ error: waitingDeliveryError.message }, { status: 500 });
    }
    const undelivered = (waitingRows ?? []) as {
      auth_id: string; client_id: string; client_name: string | null; number: string | null;
      service_type: string | null; bill_by: string | null; owner_id: string | null;
    }[];
    for (const a of undelivered) {
      if (!a.owner_id) continue;
      owed.delivery += 1;
      await admin.rpc("notify_person", {
        p_staff: a.owner_id,
        p_kind: "service_not_delivered",
        p_text:
          `${a.client_name ?? "A client"} · ${authorizationNumberLabel({ number: a.number })} · ` +
          `${a.service_type ?? ""} was to be billed by ${a.bill_by ?? "now"} and nothing says the service has been ` +
          "delivered. Record the day it was, or leave it waiting.",
        p_ref: a.auth_id,
        p_href: `/billing/authorizations/${a.auth_id}`,
        p_client: a.client_id,
        p_task_title: `Say whether the service is delivered — ${a.client_name ?? "a client"}, ${a.service_type ?? ""}`,
        p_level: "warn",
        p_source: a.auth_id,
      });
    }
  }

  return NextResponse.json({
    dry,
    rule6: { waiting: waiting.length, would_send: waiting.filter((w) => w.send).length, nudged },
    rule7: { ending: ending.length, chased },
    applications: { days: NO_REPLY_DAYS, marked_no_response: noReply },
    invoices: { chase: invoiceChase, due: invoiceDue },
    owed,
    emailed,
  });
}
