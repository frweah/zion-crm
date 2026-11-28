import { NextResponse } from "next/server";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { voiceToken, PRESENCE_REFRESH_MS } from "@/lib/twilio-voice";

/**
 * A token that makes one member of staff's browser a telephone.
 *
 * **This route has a session and no signature, which is the opposite of every
 * other route under /api/twilio.** The middleware waves the whole prefix
 * through because Twilio's own webhooks arrive with no session, so this one
 * has to check for itself - and `scripts/check-voice.mjs` asserts that every
 * route under the prefix does one of the two, by name, because "a future API
 * route that forgets to authorize should be caught by the gate rather than
 * quietly exposed by it" is what the middleware's own comment says about
 * listing paths one by one, and a prefix is the one shape that can forget.
 *
 * The identity in the token is the staff id. Everything downstream depends on
 * that: the inbound TwiML rings `<Client>` by staff id, the answered-call
 * record says who picked it up, and a call answered by "reception" is a call
 * nobody can be asked about afterwards.
 *
 * Asking for a token is also how somebody says they are at their desk. The
 * two are the same event - a browser that has just been handed a telephone is
 * a browser that can be rung - so there is no separate "I am here" call to
 * forget to make. The browser asks again every minute while the window is
 * open, and `voice_presence_seconds()` is how long one answer is trusted for.
 */
export const dynamic = "force-dynamic";

export async function GET() {
  const me = await getCurrentStaff();
  if (!me) {
    return NextResponse.json({ error: "You are not signed in." }, { status: 401 });
  }

  /**
   * The roles that take client calls are the roles that may text a client.
   * If a seat may not text somebody, the client line should not ring at that
   * desk - and the list lives in the database (`staff_on_the_phones`), so
   * this asks rather than keeps a second copy of it.
   */
  const account = process.env.TWILIO_ACCOUNT_SID;
  const keySid = process.env.TWILIO_API_KEY_SID;
  const keySecret = process.env.TWILIO_API_KEY_SECRET;
  if (!account || !keySid || !keySecret) {
    return NextResponse.json(
      { error: "Calls are not set up yet." },
      { status: 503 },
    );
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("voice_here");
  if (error) {
    // No token where the practice cannot record that somebody is on the
    // phones: a browser that can be rung but is not in the list is a browser
    // nothing will ever ring, and it would look like a broken telephone.
    return NextResponse.json({ error: error.message }, { status: 403 });
  }

  const { data: onThePhones } = await supabase.rpc("staff_on_the_phones");
  const mine = (onThePhones ?? []).some((r) => r.staff_id === me.id);
  if (!mine) {
    await supabase.rpc("voice_gone");
    return NextResponse.json(
      { error: "Your role does not take calls on the client line." },
      { status: 403 },
    );
  }

  const { token, expiresAt } = voiceToken({
    accountSid: account,
    apiKeySid: keySid,
    apiKeySecret: keySecret,
    identity: me.id,
    applicationSid: process.env.TWILIO_TWIML_APP_SID ?? null,
  });

  return NextResponse.json(
    { token, identity: me.id, expiresAt, refreshMs: PRESENCE_REFRESH_MS },
    // Never cached, anywhere. A token is one person's for an hour, and a
    // cached copy served to the next browser is somebody else answering the
    // client line.
    { headers: { "Cache-Control": "no-store, private" } },
  );
}

/**
 * And off the phones.
 *
 * Sent by the browser as its window closes, so a closed tab stops the client
 * line ringing an empty desk now rather than in ninety seconds. It is a
 * convenience and not the rule: the presence row expires on its own, which is
 * what covers a browser that was closed without warning, a laptop lid, or a
 * network that went away mid-sentence.
 */
export async function DELETE() {
  const me = await getCurrentStaff();
  if (!me) return NextResponse.json({ error: "You are not signed in." }, { status: 401 });

  const supabase = await createClient();
  const { error } = await supabase.rpc("voice_gone");
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json({ off: true });
}
