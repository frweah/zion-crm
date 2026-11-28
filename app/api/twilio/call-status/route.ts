import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { readSignedWebhook } from "@/lib/twilio";

/**
 * What became of a call.
 *
 * Twilio posts here when a call ends, and this is where a call becomes a
 * contact on a client's month - but only when somebody spoke. An answered
 * call is method 'Call' and counts; a call nobody picked up is 'Missed' and
 * counts towards nothing, because nothing happened. The deciding is in
 * `record_call_ended` rather than here, so the rule is in one place and a
 * second caller of it gets the same answer.
 *
 * It answers 200 to anything it can read, including a call the practice has
 * no row for - a call placed from Twilio's own console is not an error here,
 * and a non-2xx would have Twilio retrying it.
 *
 * The two webhooks race. A call that went to voicemail reaches this route and
 * the recording route in either order, and 'Voicemail' is more than 'the call
 * ended' - so the function keeps the stronger answer rather than whichever
 * arrived second.
 */
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  const proof = await readSignedWebhook(request);
  if (!proof.ok) {
    return NextResponse.json({ error: proof.error }, { status: proof.status });
  }

  const p = proof.params;
  const sid = (p.CallSid ?? "").trim();
  if (!sid) {
    return NextResponse.json({ error: "No call id in that payload." }, { status: 400 });
  }

  /**
   * Twilio's word for it, in ours.
   *
   * `completed` says the call ended, not that anybody spoke: a call that rang
   * out into voicemail is 'completed' too. So the thing that decides is
   * whether a desk ever picked it up, which `record_call_answered` has
   * already written by the time this arrives, and 'Answered' here is only
   * claimed when Twilio also says somebody was on the line.
   */
  const said = (p.CallStatus ?? p.DialCallStatus ?? "").trim().toLowerCase();
  const seconds = Number.parseInt(p.CallDuration ?? p.DialCallDuration ?? "", 10);
  const state =
    said === "completed"
      ? null // let the record decide: it knows whether a desk answered
      : said === "busy" || said === "no-answer" || said === "canceled"
        ? "Missed"
        : said === "failed"
          ? "Failed"
          : null;

  const supabase = createAdminClient();
  const { error } = await supabase.rpc("record_call_ended", {
    p_sid: sid,
    p_seconds: Number.isFinite(seconds) ? seconds : null,
    p_state: state,
  });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ recorded: true });
}
