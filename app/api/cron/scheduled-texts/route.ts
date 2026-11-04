import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sendScheduledTexts } from "@/lib/sms";

/**
 * Texts written for the next window (Messaging brief, A).
 *
 * Somebody writing at ten at night is offered "send at 8am" rather than being
 * turned away; this is what sends it. Every fifteen minutes, because 8am is a
 * time somebody is waiting for - the nightly reminder job runs once and would
 * hold a morning message until the evening.
 *
 * Each message goes through the same gate again on its way out: a client who
 * withdrew consent overnight is not texted.
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
  const result = await sendScheduledTexts(admin);
  // And the other half of keeping the record honest: an outgoing text that
  // has heard nothing back for five minutes is marked Not delivered and
  // whoever wrote it is told (0280). Here rather than in a job of its own
  // because this already runs every quarter hour and is already about texts
  // that have not gone yet.
  //
  // The quarter hour is why a screen does not wait for this: a list shows
  // "Not delivered" as soon as the five minutes are up, and the sweep is what
  // writes it down and says so.
  const { data: lapsed } = await admin.rpc("mark_texts_not_delivered");

  return NextResponse.json({
    ran_at: new Date().toISOString(),
    ...result,
    marked_not_delivered: lapsed ?? 0,
  });
}
