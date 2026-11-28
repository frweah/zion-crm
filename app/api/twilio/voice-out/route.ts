import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { readSignedWebhook } from "@/lib/twilio";
import { dialable, outboundTwiml, refusedTwiml } from "@/lib/twilio-voice";
import { ORG } from "@/lib/roles";

/**
 * A member of staff placing a call from a client's record.
 *
 * The TwiML app's voice URL. Twilio asks this what to do when a browser
 * holding one of our tokens dials out, and the answer is always the same
 * shape: ring the number, with the practice line as the caller id. A client
 * seeing a number they do not recognise is a client who does not answer.
 *
 * Three guards, and the first two are the ones that matter.
 *
 * **The request is Twilio's.** The signature, like every other webhook here.
 *
 * **The number is one this practice will dial.** US and Canada, ten digits
 * with the country code. This is not a formatting nicety: this URL is the one
 * place a signed-in session could ask the practice's Twilio account to call
 * anywhere in the world, and an international premium-rate number is how that
 * gets expensive before anybody notices. A number it will not dial is
 * refused out loud, to the person who dialled it, rather than silently.
 *
 * **The caller is a member of staff who is on the phones.** The identity in
 * the token is a staff id, and Twilio reports it as `From` in the shape
 * `client:<id>`. A token that has outlived its session cannot place a call.
 */
export const dynamic = "force-dynamic";

function twiml(body: string) {
  return new NextResponse(body, {
    status: 200,
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
  const asked = (p.To ?? "").trim();
  const who = (p.From ?? "").trim();
  const identity = who.startsWith("client:") ? who.slice("client:".length) : "";

  const to = dialable(asked);
  if (!to) {
    return twiml(
      refusedTwiml("That number cannot be dialled from here. Call it from a telephone instead."),
    );
  }

  const supabase = createAdminClient();

  const { data: present } = await supabase.rpc("staff_on_the_phones");
  const onThePhones = (present ?? []).some((r) => r.staff_id === identity);
  if (!identity || !onThePhones) {
    return twiml(refusedTwiml("Your line is not signed in. Open the CRM and try again."));
  }

  if (sid) {
    const { error } = await supabase.rpc("record_call_started", {
      p_sid: sid,
      p_direction: "Outbound",
      p_from: callerId(),
      p_to: to,
    });
    if (error) console.error(`[twilio] an outbound call was not recorded: ${error.message}`);
    // Who placed it, said now rather than waited for: an outbound call is
    // answered by the person who made it, and `record_call_answered` is what
    // puts their name on the contact-log line when it ends.
    await supabase.rpc("record_call_answered", { p_sid: sid, p_identity: identity });
  }

  return twiml(outboundTwiml({ to, callerId: callerId() }));
}

/**
 * What the person being called sees.
 *
 * The number the Twilio account actually holds, which during the move is the
 * test number and after it is the practice line. It has to be a number the
 * account owns or Twilio refuses the call outright - so this is not a
 * cosmetic choice, and `ORG.clientPhone` is only the fallback for a
 * deployment where nobody has set the variable yet.
 */
function callerId(): string {
  return (
    dialable(process.env.TWILIO_FROM_NUMBER ?? "") ??
    dialable(ORG.clientPhone) ??
    ORG.clientPhone
  );
}
