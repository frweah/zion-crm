import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { readSignedWebhook } from "@/lib/twilio";

/**
 * What happened to a text after Twilio took it.
 *
 * Twilio answering "queued" is not the carrier answering "delivered". The
 * practice learned that on the other provider the expensive way: for a year
 * it knew only that GoHighLevel had accepted a message, so a text the carrier
 * dropped an hour later went on reading as sent and 'Delivered' was
 * unknowable (0287). Every message is sent with this as its StatusCallback,
 * so the answer comes back.
 *
 * Nothing is trusted from the body except the message id and the status word.
 * There is no client in it and no phone number in it: the id already says
 * which row this is about, and a webhook that could name a client would be a
 * way to write on somebody's record over HTTP.
 *
 * It answers 200 to anything it can read, including a status for a message
 * the practice has no row for — a text sent from Twilio's own console is not
 * an error here, and a non-2xx would have Twilio retrying it.
 *
 * The status words are mapped in the database, not here (0392). Twilio's
 * vocabulary and GoHighLevel's overlap but are not the same, and one place
 * that knows both is one place to correct when a carrier adds a word.
 */
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  const proof = await readSignedWebhook(request);
  if (!proof.ok) {
    return NextResponse.json({ error: proof.error }, { status: proof.status });
  }

  const p = proof.params;
  const providerId = (p.MessageSid ?? p.SmsSid ?? "").trim();
  const status = (p.MessageStatus ?? p.SmsStatus ?? "").trim();

  if (!providerId) {
    return NextResponse.json({ error: "No message id in that payload." }, { status: 400 });
  }
  if (!status) {
    return NextResponse.json({ error: "No status in that payload." }, { status: 400 });
  }

  /**
   * Twilio's error code is the half worth keeping.
   *
   * The message is often generic where the code is specific, and the code is
   * what a search finds: 21610 is the one this practice will meet, and it
   * means the person has texted STOP and the messaging service refused on
   * their behalf. Recorded on the text, so the row says why rather than
   * saying nothing.
   */
  const code = (p.ErrorCode ?? "").trim();
  const said = (p.ErrorMessage ?? "").trim();
  const why = code && said ? `${code} ${said}` : code || said || null;

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("record_text_status", {
    p_provider_id: providerId,
    p_status: status,
    p_error: why,
    // Kept verbatim. What a provider sends is theirs to change, and the row it
    // arrived on is the only place the change will be visible afterwards.
    p_payload: p as never,
  });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  const row = Array.isArray(data) ? data[0] : data;
  return NextResponse.json({ matched: Boolean(row?.matched), status: row?.status ?? null });
}
