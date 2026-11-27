import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { carrierNotReady } from "@/lib/text-provider";
import { sendDueReminders } from "@/lib/sms";

/**
 * Tomorrow's appointment reminders.
 *
 * Runs late afternoon, Utah time, so a reminder about tomorrow arrives while
 * somebody can still do something about it. Behind the same shared secret as
 * the other cron routes: this one holds a service-role client and can text
 * clients, which makes it the most worth protecting of the three.
 *
 * It sends nothing on its own authority. The database decides who may be
 * texted, sms_due_reminders decides who is due, and this walks the list.
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/sms
 */
export const dynamic = "force-dynamic";

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

  // Asked once, before the list is walked, so a missing key is one line here
  // rather than one failed message per client. Which keys matter depends on
  // which carrier is live, so the question is asked of the switch rather than
  // of one provider's environment variables.
  const notReady = await carrierNotReady(supabase);
  if (notReady) {
    return NextResponse.json({ error: notReady }, { status: 500 });
  }

  const result = await sendDueReminders(supabase);

  // Errors come back in the body rather than as a failed request: a run where
  // nine reminders went and one did not is a success with a note, and a cron
  // job that reports failure for that gets ignored by the second week.
  return NextResponse.json({
    ran_at: new Date().toISOString(),
    ...result,
  });
}
