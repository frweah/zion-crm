import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";

/**
 * The two things the clock does on its own.
 *
 * A session nobody closed is told about at ten hours and closed at fourteen,
 * at the last thing the practice saw that person do. And somebody who was
 * expected at nine and has not clocked in by a quarter past is reminded -
 * them only, as asked, and never by text.
 *
 * Quarter-hourly, because both numbers are about minutes: a reminder that
 * arrives an hour late is an accusation rather than a reminder, and a session
 * closed an hour after fourteen hours pays for an hour nobody worked.
 *
 * Both rules live in the database (0293). This route carries nothing but the
 * request and what happened.
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

  const admin = createAdminClient();
  const [{ data: closed, error: closeError }, { data: reminded, error: remindError }] =
    await Promise.all([
      admin.rpc("close_forgotten_sessions"),
      admin.rpc("remind_to_clock_in"),
    ]);

  return NextResponse.json({
    ran_at: new Date().toISOString(),
    sessions_closed: closed ?? 0,
    reminded_to_clock_in: reminded ?? 0,
    errors: [closeError?.message, remindError?.message].filter(Boolean),
  });
}
