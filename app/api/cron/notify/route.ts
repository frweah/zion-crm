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
  const recipients = staff ?? [];

  if (rows.length === 0) {
    return NextResponse.json({ ok: true, notifications: 0, emails: 0, note: "nothing new" });
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
    ...(failed.length ? { failed } : {}),
  });
}
