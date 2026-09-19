import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sendEmail, emailConfigured } from "@/lib/email";
import { ORG } from "@/lib/roles";

/**
 * The unread-message email (Messaging brief, foundation). Every fifteen
 * minutes: anybody who has asked for it, away or offline for thirty minutes,
 * with staff messages waiting more than thirty, is told how many and in which
 * conversations - never what they say. Each message is mentioned once
 * (messages_digest_sent). Behind the cron secret, as the service role.
 */
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  return handle(request);
}
export async function POST(request: NextRequest) {
  return handle(request);
}

async function handle(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (!secret) return NextResponse.json({ error: "CRON_SECRET is not set" }, { status: 500 });
  if (request.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  if (!emailConfigured()) return NextResponse.json({ ok: false, error: "email is not configured" }, { status: 503 });

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("messages_digest_due");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  type Row = { staff_id: string; email: string; name: string; conversation_id: string; conversation_label: string; unread: number; through_seq: number };
  const byPerson = new Map<string, Row[]>();
  for (const r of (data ?? []) as Row[]) {
    if (!r.unread) continue;
    byPerson.set(r.staff_id, [...(byPerson.get(r.staff_id) ?? []), r]);
  }

  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  let sent = 0;
  for (const rows of byPerson.values()) {
    const total = rows.reduce((s, r) => s + r.unread, 0);
    const result = await sendEmail({
      to: rows[0].email,
      subject: `Zion CRM - ${total} unread message${total === 1 ? "" : "s"}`,
      text: [
        `${rows[0].name.split(" ")[0]},`,
        "",
        `${total} message${total === 1 ? " is" : "s are"} waiting for you in the CRM:`,
        ...rows.map((r) => `- ${r.unread} in ${r.conversation_label}`),
        "",
        `Read them: ${site}/messages`,
        "",
        "What they say stays in the CRM. You asked for this email on the Messages screen, and can stop it there.",
        "",
        ORG.name,
      ].join("\n"),
    });
    if (!result.ok) continue;
    sent += 1;
    for (const r of rows) {
      await supabase.rpc("messages_digest_sent", { p_staff: r.staff_id, p_conversation: r.conversation_id, p_through: r.through_seq });
    }
  }
  return NextResponse.json({ ok: true, people: byPerson.size, emails: sent });
}
