"use client";

import { createClient } from "@/lib/supabase/client";

/**
 * A recording attached when somebody clocks out.
 *
 * Its own file because it is its own rule. A PDF, a Word file or a photo of
 * the day's work is the person's own and goes in their staff file. A
 * recording is of a conversation with a client: `attachments.client_id` is
 * not null, the restricted-by-default rule applies to it, and the recordings
 * pipeline reads it from the client's record and nowhere else. So a recording
 * without a client has nowhere to go that anything can read.
 *
 * Keeping the two apart in two files is also what lets
 * `check-upload-types` do its job: it pairs the file types a picker offers
 * with the bucket that file uploads to, and a module that named both buckets
 * would be asking it to guess which types went where.
 */
export function ClockRecordingField({
  disabled,
  onPick,
}: {
  /** No client chosen yet, so there is nowhere for a recording to go. */
  disabled: boolean;
  onPick: (file: File | null) => void;
}) {
  return (
    <>
      <label className="field">
        <span>Or a recording of a meeting</span>
        <input
          id="clock-recording"
          type="file"
          disabled={disabled}
          accept=".m4a,.mp3,.mp4,.wav,.ogg,.webm,.aac,.flac"
          onChange={(e) => onPick(e.target.files?.[0] ?? null)}
        />
      </label>
      <p className="lock">
        {disabled
          ? "Choose the client first — a recording goes on their record"
          : "It goes on the client's record and is read for you"}
      </p>
    </>
  );
}

/**
 * The bytes, then the row, then the queue.
 *
 * `start_recording` is reported but never fatal: the audio is on the client's
 * record either way, and a queue that refused it is not a reason to lose
 * somebody's clock-out.
 */
export async function putRecording({
  file,
  client,
  staffId,
}: {
  file: File;
  client: string;
  staffId: string;
}): Promise<{ attachment: string | null; error: string | null }> {
  if (!client) {
    return { attachment: null, error: "Choose the client the recording is about." };
  }
  if (file.size > 50 * 1024 * 1024) {
    return { attachment: null, error: `${file.name} is over 50 MB — record at a lower quality.` };
  }

  const supabase = createClient();
  const ext = file.name.includes(".") ? file.name.split(".").pop() : "";
  // The bucket compares the bare type: "audio/webm;codecs=opus" is refused
  // where "audio/webm" is taken.
  const type = (file.type || "application/octet-stream").split(";")[0];
  const path = `clients/${client}/${crypto.randomUUID()}${ext ? `.${ext}` : ""}`;

  const { error } = await supabase.storage
    .from("client-files")
    .upload(path, file, { contentType: type });
  if (error) {
    const said = error.message.toLowerCase();
    return {
      attachment: null,
      error:
        said.includes("mime") || said.includes("type")
          ? `${type} is not a recording the record takes.`
          : `${file.name} did not go up. ${error.message}`,
    };
  }

  const { data: row, error: rowError } = await supabase
    .from("attachments")
    .insert({
      client_id: client,
      storage_path: path,
      filename: file.name,
      mime_type: type,
      size_bytes: file.size,
      category: "Recording",
      uploaded_by: staffId,
    })
    .select("id")
    .single();

  if (rowError || !row) {
    await supabase.storage.from("client-files").remove([path]);
    return { attachment: null, error: rowError?.message ?? "The record would not take that recording." };
  }

  await supabase.rpc("start_recording", { p_attachment: row.id });
  return { attachment: row.id, error: null };
}
