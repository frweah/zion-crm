import { NextResponse, type NextRequest } from "next/server";
import { createHash, randomUUID } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { readSignedWebhook, recordingAudio } from "@/lib/twilio";
import { INBOX_BUCKET } from "@/lib/inbox-storage";

/**
 * Somebody left a message.
 *
 * The order here is the point, and it is the same order `lib/sms.ts` sends a
 * text in: write the record first, then do the slow thing.
 *
 *   1. `record_voicemail` - the call is marked, and a contact-log line
 *      appears on the client saying a message was left. No transcript, no
 *      audio, no waiting. The client rang at ten past four whether or not
 *      anything else works, and this is the half that makes the practice
 *      answer them.
 *   2. The audio is fetched from Twilio, put in the client's folder, and
 *      filed as an attachment with a `recordings` row waiting beside it.
 *   3. The quarter-hourly recordings sweep reads it through Azure, and a
 *      trigger puts the words onto the line from step 1.
 *
 * Anything after step 1 can fail without losing the message. A fetch that
 * times out leaves a client with "a message, not read yet" and a call record
 * holding the recording id, which is somebody's to chase - rather than a
 * silent nothing, which is what a route that fetched first would leave.
 *
 * A message from a number nobody has placed stops at step 1 and stays on the
 * call record: there is no client folder to put it in, because there is no
 * client. Staff say whose it is.
 */
export const dynamic = "force-dynamic";
export const maxDuration = 120;

export async function POST(request: NextRequest) {
  const proof = await readSignedWebhook(request);
  if (!proof.ok) {
    return NextResponse.json({ error: proof.error }, { status: proof.status });
  }

  const p = proof.params;
  const sid = (p.CallSid ?? "").trim();
  const recordingSid = (p.RecordingSid ?? "").trim();
  const status = (p.RecordingStatus ?? "").trim().toLowerCase();
  const seconds = Number.parseInt(p.RecordingDuration ?? "", 10);

  if (!sid || !recordingSid) {
    return NextResponse.json({ error: "No call or recording id in that payload." }, { status: 400 });
  }

  // Twilio posts 'in-progress' and then 'completed'. Only a finished
  // recording has anything to fetch, and a failed one is worth marking so
  // somebody knows a caller spoke into nothing.
  if (status && status !== "completed") {
    return NextResponse.json({ ignored: status });
  }

  const supabase = createAdminClient();

  const { data: line, error } = await supabase.rpc("record_voicemail", {
    p_sid: sid,
    p_recording_sid: recordingSid,
    p_seconds: Number.isFinite(seconds) ? seconds : null,
  });
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  // No client, no folder. The message is on the call record and a member of
  // staff can say whose it is.
  if (!line) {
    console.log("[twilio] a voicemail arrived from a number nobody has placed");
    return NextResponse.json({ recorded: true, filed: false, why: "no client on that number" });
  }

  const { data: call } = await supabase
    .from("voice_calls")
    .select("id, client_id, attachment_id")
    .eq("call_sid", sid)
    .maybeSingle();

  if (call?.attachment_id) {
    return NextResponse.json({ recorded: true, filed: true, already: true });
  }

  const audio = await recordingAudio(recordingSid);
  if (!audio.ok) {
    console.error(`[twilio] a voicemail could not be fetched: ${audio.error}`);
    // 200 on purpose. The message is recorded and the client is owed a reply;
    // a retry would write nothing new, and Twilio retrying for ever teaches
    // nobody anything. The call record holds the recording id to chase.
    return NextResponse.json({ recorded: true, filed: false, why: audio.error });
  }

  const path = `clients/${call?.client_id}/${randomUUID()}.mp3`;
  const put = await supabase.storage
    .from(INBOX_BUCKET)
    .upload(path, audio.data.bytes, { contentType: "audio/mpeg" });
  if (put.error) {
    console.error(`[twilio] a voicemail could not be stored: ${put.error.message}`);
    return NextResponse.json({ recorded: true, filed: false, why: put.error.message });
  }

  const { error: filed } = await supabase.rpc("file_voicemail", {
    p_sid: sid,
    p_storage_path: path,
    p_filename: `Voicemail ${new Date().toISOString().slice(0, 10)}.mp3`,
    p_mime: "audio/mpeg",
    p_bytes: audio.data.bytes.length,
    p_sha256: createHash("sha256").update(audio.data.bytes).digest("hex"),
    p_seconds: Number.isFinite(seconds) ? seconds : null,
  });

  if (filed) {
    // Unrecorded is invisible: nobody could find it and nobody could delete
    // it, so it does not stay in the bucket (the rule mail-filing follows).
    await supabase.storage.from(INBOX_BUCKET).remove([path]);
    console.error(`[twilio] a voicemail was stored and not filed: ${filed.message}`);
    return NextResponse.json({ recorded: true, filed: false, why: filed.message });
  }

  return NextResponse.json({ recorded: true, filed: true });
}
