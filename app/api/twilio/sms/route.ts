import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { readSignedWebhook } from "@/lib/twilio";

/**
 * A client texting back, on Twilio.
 *
 * The same job as app/api/sms/inbound/route.ts does for GoHighLevel, and
 * deliberately the same shape: the number and the words are handed to
 * `record_incoming_sms` and nothing else is trusted. There is no client id in
 * a webhook body and there is no consent flag in one — a webhook that could
 * say "this person consented" would be a way to grant consent by HTTP, and a
 * webhook that could name a client would be a way to write on somebody's
 * record over HTTP.
 *
 * Everything the reply then means is the database's: the rating parsed before
 * the keywords, STOP withdrawing consent for the number it came from, the
 * contact-log line, the thread. None of it is repeated here, because a second
 * provider must not become a second set of rules — which is the whole reason
 * this file is as short as it is.
 *
 * **Advanced Opt-Out and our own table both run, and ours decides.** Twilio's
 * messaging service answers STOP itself and will refuse to deliver to a
 * number that has opted out, which is the carrier's rule and not ours to
 * switch off. Our consent table is the practice's record, and it is what the
 * sending gate asks before any text is written. If the two ever disagree the
 * practice sends nothing: Twilio refuses, and our gate refuses, and a message
 * needs both to say yes.
 *
 * Set it up on the messaging service as the inbound webhook, POST, to
 * https://crm.zionvocrehab.com/api/twilio/sms — the signature is checked
 * against that exact URL, so the path in Twilio and the path here have to
 * agree character for character.
 */
export const dynamic = "force-dynamic";

/** What Twilio answers an inbound message with when there is nothing to say. */
const EMPTY_TWIML = '<?xml version="1.0" encoding="UTF-8"?><Response></Response>';

function twiml(status = 200) {
  return new NextResponse(EMPTY_TWIML, {
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
  const phone = (p.From ?? "").trim();
  const body = p.Body ?? "";

  if (!phone) {
    return NextResponse.json({ error: "No phone number in that payload." }, { status: 400 });
  }

  /**
   * The picture, where there is one.
   *
   * Twilio says how many there are and numbers them from zero, so unlike the
   * other provider there is nothing to guess: the first one is MediaUrl0 and
   * its type is MediaContentType0. Referenced rather than copied — the media
   * stays on the provider's side with the provider's retention, and a copy
   * here would be a second place a client's photograph lives.
   */
  const howMany = Number(p.NumMedia ?? "0");
  const media = howMany > 0 ? (p.MediaUrl0 ?? null) : null;
  const mediaType = howMany > 0 ? (p.MediaContentType0 ?? null) : null;

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("record_incoming_sms", {
    p_phone: phone,
    p_body: body,
    p_provider_id: (p.MessageSid ?? p.SmsSid ?? "").trim() || null,
    p_media: media,
    p_media_type: mediaType,
    // Kept verbatim. What a provider sends is theirs to change, and the row it
    // arrived on is the only place the change will be visible afterwards.
    p_payload: p as never,
  });

  if (error) {
    // Not TwiML. A non-2xx is how this shows up in Twilio's own error log,
    // which is the only place anybody would find out that a client's text was
    // refused — Twilio does not retry an inbound webhook, so a quiet 200 here
    // would lose the message with nothing to look at.
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  const row = Array.isArray(data) ? data[0] : data;
  console.log(
    `[twilio] inbound ${row?.action ?? "logged"}${row?.client_id ? " (matched)" : " (unmatched)"}`,
  );

  // Empty TwiML: the message is recorded and nobody is answered automatically.
  // Whatever reply is owed is a person's to write, on the thread.
  return twiml();
}
