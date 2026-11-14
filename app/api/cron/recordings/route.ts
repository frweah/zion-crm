import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { INBOX_BUCKET } from "@/lib/inbox-storage";
import {
  askAboutReading,
  draftSummary,
  recordingsEnabled,
  recordingsNotReady,
  startReading,
} from "@/lib/recordings";

/**
 * Reading the recordings (item F).
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/recordings
 *   …?dry=1   what it would do, doing nothing
 *
 * Two jobs in one run, because they are two halves of one thing: send the
 * recordings nobody has sent yet, and ask about the jobs already running.
 * Azure batch transcription takes minutes, so nothing here waits - a
 * recording submitted on this run is read on a later one.
 *
 * The cost guard is not in this file. `recordings_to_read` applies it as it
 * answers, so a recording over the month's hours is held before this route
 * ever sees it - which means the limit cannot be got round by calling this
 * twice.
 *
 * Every refusal is Azure's own words, recorded on the recording. A wrong
 * request body shows up as "Azure Speech refused the recording: …" on the
 * screen a person is looking at, rather than as a recording that sits in
 * Reading for ever.
 */
export const dynamic = "force-dynamic";
export const maxDuration = 300;

/**
 * Two hours, not ten minutes.
 *
 * The URL is handed to Azure rather than used here: Azure queues the job,
 * downloads the audio when it gets to it, and a queue of other people's
 * recordings is not something this practice can see. Ten minutes - which is
 * right for the document agent, reading a photo now - would expire while the
 * job waited.
 */
const AUDIO_URL_SECONDS = 2 * 60 * 60;

export async function POST(request: NextRequest) {
  return handle(request);
}
export async function GET(request: NextRequest) {
  return handle(request);
}

async function handle(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (!secret) return NextResponse.json({ error: "CRON_SECRET is not set" }, { status: 500 });
  if (request.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const dry = request.nextUrl.searchParams.get("dry") === "1";

  if (!recordingsEnabled()) {
    // Not an error: the owner turns this on, and until then the route says so
    // rather than failing a deploy check that pings it.
    return NextResponse.json({ ran: false, why: "RECORDINGS_ENABLED is not true" });
  }
  const notReady = recordingsNotReady();
  if (notReady) return NextResponse.json({ ran: false, why: notReady }, { status: 503 });

  const admin = createAdminClient();
  const { data: rows, error } = await admin.rpc("recordings_to_read");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const queue = (rows ?? []) as unknown as {
    id: string;
    attachment_id: string;
    client_id: string;
    storage_path: string;
    mime_type: string;
    state: string;
    job_url: string;
    minutes_left: number;
  }[];

  const out = {
    dry,
    waiting: queue.filter((r) => r.state === "Waiting").length,
    reading: queue.filter((r) => r.state === "Reading").length,
    sent: 0,
    read: 0,
    drafted: 0,
    failed: 0,
    still_running: 0,
    problems: [] as string[],
  };
  if (dry) return NextResponse.json(out);

  // ── the ones nobody has sent ───────────────────────────────
  for (const row of queue.filter((r) => r.state === "Waiting")) {
    if (!row.storage_path) {
      await admin.rpc("recording_failed", {
        p_id: row.id,
        p_reason: "There is no stored file for that recording.",
      });
      out.failed += 1;
      continue;
    }

    const { data: signed, error: signError } = await admin.storage
      .from(INBOX_BUCKET)
      .createSignedUrl(row.storage_path, AUDIO_URL_SECONDS);
    if (signError || !signed?.signedUrl) {
      out.problems.push(`${row.id}: the audio could not be signed — ${signError?.message ?? "no URL"}`);
      continue;
    }

    const started = await startReading({
      audioUrl: signed.signedUrl,
      label: `Zion recording ${row.id}`,
    });
    if (!started.ok) {
      await admin.rpc("recording_failed", { p_id: row.id, p_reason: started.error });
      out.failed += 1;
      out.problems.push(`${row.id}: ${started.error}`);
      continue;
    }
    const { error: markError } = await admin.rpc("recording_reading", {
      p_id: row.id,
      p_job_url: started.data,
    });
    if (markError) {
      out.problems.push(`${row.id}: sent to Azure but not recorded — ${markError.message}`);
      continue;
    }
    out.sent += 1;
  }

  // ── and the ones already at Azure ──────────────────────────
  for (const row of queue.filter((r) => r.state === "Reading" && r.job_url)) {
    const asked = await askAboutReading(row.job_url);
    if (!asked.ok) {
      out.problems.push(`${row.id}: ${asked.error}`);
      continue;
    }
    if (!asked.data.done) {
      out.still_running += 1;
      continue;
    }
    if (!asked.data.reading) {
      await admin.rpc("recording_failed", {
        p_id: row.id,
        p_reason: asked.data.failure ?? "Azure could not read it.",
      });
      out.failed += 1;
      continue;
    }

    const reading = asked.data.reading;
    const { error: readError } = await admin.rpc("recording_read", {
      p_id: row.id,
      p_turns: reading.turns as never,
      p_transcript: reading.transcript,
      p_minutes: reading.minutes,
    });
    if (readError) {
      out.problems.push(`${row.id}: the reading did not save — ${readError.message}`);
      continue;
    }
    out.read += 1;

    /*
     * An empty reading is a reading, and there is nothing to draft from it.
     *
     * The same rule a photo follows: the recording stays Read, with "there
     * were no words in it" on it, and nobody is asked to confirm a summary of
     * silence.
     */
    if (reading.transcript.trim() === "") continue;

    const { data: client } = await admin
      .from("clients")
      .select("name")
      .eq("id", row.client_id)
      .maybeSingle();

    const draft = await draftSummary({
      transcript: reading.transcript,
      clientFirstName: (client?.name ?? "").trim().split(" ")[0] ?? "",
    });
    if (!draft.ok) {
      // The words are safe and on the recording; only the draft failed. It
      // stays Read, which a person can still confirm by writing the summary
      // themselves, and the reason says why there is no draft.
      out.problems.push(`${row.id}: ${draft.error}`);
      continue;
    }
    const { error: draftError } = await admin.rpc("recording_drafted", {
      p_id: row.id,
      p_summary: draft.data as never,
    });
    if (draftError) {
      out.problems.push(`${row.id}: the draft did not save — ${draftError.message}`);
      continue;
    }
    out.drafted += 1;
  }

  return NextResponse.json(out);
}
