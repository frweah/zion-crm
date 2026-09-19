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
  const result = await sendScheduledTexts(createAdminClient());
  return NextResponse.json({ ran_at: new Date().toISOString(), ...result });
}
