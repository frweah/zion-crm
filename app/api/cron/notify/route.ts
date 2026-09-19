import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sendEmail, emailConfigured } from "@/lib/email";
import { ORG } from "@/lib/roles";

/**
 * Nightly digest.
 *
 * Recalculates the notifications, then emails each active staff member the
 * open items addressed to their role. Runs as the service role because cron
 * is not a logged-in user, which is exactly why it is behind a shared secret:
 * an unauthenticated endpoint holding a service-role client would be the
 * softest target in the system.
 *
 * Triggered by Supabase pg_cron or Vercel Cron once the app is deployed:
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/notify
 */
export const dynamic = "force-dynamic";

type Row = {
  id: string;
  level: string;
  text: string;
  roles: string[];
  href: string | null;
};

export async function POST(request: NextRequest) {
  return handle(request);
}

export async function GET(request: NextRequest) {
  return handle(request);
}

async function handle(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "CRON_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const supabase = createAdminClient();

  const { error: genError } = await supabase.rpc("generate_notifications");
  if (genError) {
    return NextResponse.json({ error: genError.message }, { status: 500 });
  }

  // Onboarding reminders go every night a step is open, unlike the digest's
  // once-per-item: the person asked to finish is the one who has to act.
  const onboardingReminders = emailConfigured() ? await remindOnboarding(supabase) : 0;

  const [{ data: pending }, { data: staff }] = await Promise.all([
    supabase
      .from("notifications")
      .select("id, level, text, roles, href")
      .is("resolved_at", null)
      .is("emailed_at", null)
      .order("level"),
    supabase
      .from("staff")
      .select("id, name, email, role")
      .eq("active", true)
      .not("accepted_at", "is", null),
  ]);

  const rows = (pending ?? []) as Row[];

  // A staff row can exist without an email — the Billing seat is a placeholder
  // until someone is named. Nothing can be sent to it, and it is not an error.
  const recipients = (staff ?? []).filter(
    (s): s is typeof s & { email: string } => Boolean(s.email),
  );

  if (rows.length === 0) {
    return NextResponse.json({ ok: true, notifications: 0, emails: 0, onboardingReminders, note: "nothing new" });
  }
  if (!emailConfigured()) {
    return NextResponse.json(
      { ok: false, notifications: rows.length, emails: 0, error: "email is not configured" },
      { status: 503 },
    );
  }

  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  const sent: string[] = [];
  const failed: string[] = [];

  for (const person of recipients) {
    const mine = rows.filter((r) => r.roles.includes(person.role));
    if (mine.length === 0) continue;

    const urgent = mine.filter((r) => r.level === "bad");
    const rest = mine.filter((r) => r.level !== "bad");

    const body = [
      `${person.name.split(" ")[0]},`,
      "",
      `${mine.length} item${mine.length === 1 ? "" : "s"} need attention in the CRM.`,
      "",
      ...(urgent.length
        ? ["NEEDS ACTION NOW", ...urgent.map((r) => `- ${r.text}`), ""]
        : []),
      ...(rest.length ? ["COMING UP", ...rest.map((r) => `- ${r.text}`), ""] : []),
      `Open the CRM: ${site}/dashboard`,
      "",
      "This is sent once per item. You will not be reminded about the same thing",
      "again tomorrow — it stays on your dashboard until it clears.",
      "",
      ORG.name,
    ].join("\n");

    const result = await sendEmail({
      to: person.email,
      subject: `Zion CRM — ${mine.length} item${mine.length === 1 ? "" : "s"} need attention`,
      text: body,
    });

    if (result.ok) sent.push(person.email);
    else failed.push(`${person.email}: ${result.error}`);
  }

  // Marked only after the sending pass, so a notification addressed to two
  // roles is not marked emailed by the first recipient and skipped for the
  // second. If every send failed, nothing is marked and tomorrow tries again.
  if (sent.length > 0) {
    await supabase
      .from("notifications")
      .update({ emailed_at: new Date().toISOString() })
      .in(
        "id",
        rows.map((r) => r.id),
      );
  }

  return NextResponse.json({
    ok: failed.length === 0,
    notifications: rows.length,
    emails: sent.length,
    onboardingReminders,
    ...(failed.length ? { failed } : {}),
  });
}

const STEP_LABEL: Record<string, string> = {
  personal_details: "your personal details and an emergency contact",
  identity_documents: "your identity documents",
  certifications_submitted: "your certifications, or confirming you hold none yet",
  tax_form_signed: "your tax form",
  policy_signed: "the data-handling policy",
  payment_setup: "how you would like to be paid",
};

/**
 * One email to each person with onboarding steps still open (0100), at most
 * once a day however often this runs. Only once they have signed in: before
 * that it is the invite that is outstanding, and Admin resends it.
 */
async function remindOnboarding(supabase: ReturnType<typeof createAdminClient>): Promise<number> {
  const today = new Date().toLocaleDateString("en-CA", { timeZone: "America/Denver" });
  const { data: open } = await supabase
    .from("staff_onboarding")
    .select("staff_id, last_reminded_on, staff:staff!staff_onboarding_staff_id_fkey(name, email, active, accepted_at)")
    .is("completed_at", null);

  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  let sent = 0;
  for (const o of open ?? []) {
    const person = Array.isArray(o.staff) ? o.staff[0] : o.staff;
    if (!person?.active || !person.accepted_at || !person.email) continue;
    if (o.last_reminded_on === today) continue;

    const { data: steps } = await supabase.rpc("onboarding_open_steps", { p_staff: o.staff_id });
    const list = (steps as string[] | null) ?? [];
    if (list.length === 0) continue;

    const result = await sendEmail({
      to: person.email,
      subject: `Zion CRM - ${list.length} onboarding step${list.length === 1 ? "" : "s"} left`,
      text: [
        `${person.name.split(" ")[0]},`,
        "",
        `Your onboarding is nearly there. Still to do:`,
        ...list.map((k) => `- ${STEP_LABEL[k] ?? k}`),
        "",
        `Pick up where you left off: ${site}/paperwork/onboarding`,
        "",
        "You will get this each evening until it is done.",
        "",
        ORG.name,
      ].join("\n"),
    });
    if (result.ok) {
      sent += 1;
      await supabase.from("staff_onboarding").update({ last_reminded_on: today }).eq("staff_id", o.staff_id);
    }
  }
  return sent;
}
