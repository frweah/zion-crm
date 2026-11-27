import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { callbackUrl, readSignedWebhook } from "@/lib/twilio";
import { inboundTwiml } from "@/lib/twilio-voice";

/**
 * Somebody is ringing the practice line.
 *
 * Every desk that is actually there rings at once, for twenty-five seconds,
 * and then the caller gets the greeting and a recorder. There is no cell
 * phone fallback, by the owner's instruction: a call that rings a mobile
 * nobody is holding is a caller waiting twice as long for the same voicemail.
 *
 * "Actually there" is the part worth being careful about. It is not who has a
 * token - a token issued five hours ago says nothing about whether anybody is
 * at the desk - it is who has said so in the last ninety seconds, which the
 * browser does every minute while its window is open. Nobody there means no
 * `<Dial>` at all and the greeting immediately, which is a better answer than
 * twenty-five seconds of ringing into an empty office.
 *
 * The caller is named here rather than in the browser, because the browser
 * has no way to look a number up and an incoming banner showing only a phone
 * number is one somebody has to go and search while it rings. The name comes
 * from `client_numbers`, the same view the texting gate reads, so a banner and
 * a text thread cannot disagree about who somebody is.
 */
export const dynamic = "force-dynamic";

function twiml(body: string, status = 200) {
  return new NextResponse(body, {
    status,
    headers: { "Content-Type": "text/xml; charset=utf-8" },
  });
}

export async function POST(request: NextRequest) {
  const proof = await readSignedWebhook(request);
  if (!proof.ok) {
    return NextResponse.json({ error: proof.error }, { status: proof.status });
  }

  const p = proof.params;
  const sid = (p.CallSid ?? "").trim();
  const from = (p.From ?? "").trim();
  const to = (p.To ?? "").trim();

  if (!sid || !from) {
    return NextResponse.json({ error: "No call id or caller in that payload." }, { status: 400 });
  }

  const supabase = createAdminClient();

  /**
   * The call is on the record before anybody's browser rings.
   *
   * A call that nothing answers and nothing records still happened, and a
   * caller who rang four times is a thing somebody should be able to see.
   */
  const { data: started, error } = await supabase.rpc("record_call_started", {
    p_sid: sid,
    p_direction: "Inbound",
    p_from: from,
    p_to: to,
  });

  if (error) {
    // The caller still gets the greeting. A call the practice could not write
    // down is not a reason to hang up on somebody.
    console.error(`[twilio] an inbound call was not recorded: ${error.message}`);
  }

  const row = Array.isArray(started) ? started[0] : started;

  const { data: present } = await supabase.rpc("staff_on_the_phones");
  const ring = (present ?? []).map((r) => r.staff_id).filter((id): id is string => Boolean(id));

  console.log(`[twilio] inbound call, ringing ${ring.length} desk(s)`);

  return twiml(
    inboundTwiml({
      callerId: from,
      ring,
      callerLabel: row?.label ?? "Unknown caller",
      clientId: row?.client_id ?? null,
      recordingStatusCallback: callbackUrl("/api/twilio/recording-status"),
    }),
  );
}
