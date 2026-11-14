"use client";

import { useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { clockOutWith, summaryChoices, type ClockChoices } from "./clock-actions";
import { ClockRecordingField, putRecording } from "./clock-recording";

/**
 * What the day was, asked once, at clock out (owner, 14 November 2026).
 *
 * 0293 asked nothing here on purpose - "somebody pressing it at six in the
 * evening should not meet a form" - and it was right about the form and
 * wrong about the outcome: every session anybody clocked since carried no
 * description at all, because the fuller entry lived on another screen and
 * nobody went to it.
 *
 * So the asking is here, and the thing that made it wrong is not: **nothing
 * is required**. "Clock out without saying" is a button, not a trap door, and
 * a person who takes it is clocked out. The day is then flagged on their My
 * day and their manager's until somebody says what it was, which is a
 * different kind of pressure from a form that will not let go of you.
 *
 * The lists are fetched when the panel opens rather than carried by the
 * header on every page. The header is on every screen in the practice; one
 * more query per page load to fill a dropdown nobody has opened would be
 * paid for on every screen, all day.
 */
export function ClockSummary({
  staffId,
  onDone,
  onCancel,
}: {
  staffId: string;
  /** Clocked out. The parent closes the panel and lets the page refresh. */
  onDone: (said: string | null) => void;
  onCancel: () => void;
}) {
  const [choices, setChoices] = useState<ClockChoices | null>(null);
  const [said, setSaid] = useState("");
  const [category, setCategory] = useState("");
  const [client, setClient] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const [recording, setRecording] = useState<File | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const box = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    let live = true;
    void summaryChoices().then((c) => {
      if (live) setChoices(c);
    });
    box.current?.focus();
    return () => {
      live = false;
    };
  }, []);

  async function out(withSummary: boolean) {
    setProblem(null);
    setBusy(withSummary ? "Clocking out" : "Clocking out");

    let staffFile: string | null = null;
    let attachment: string | null = null;

    if (withSummary && file) {
      const put = await putTheFile({ file, staffId });
      if (put.error) {
        setProblem(put.error);
        setBusy(null);
        return;
      }
      staffFile = put.staffFile;
    }

    if (withSummary && recording) {
      const put = await putRecording({ file: recording, client, staffId });
      if (put.error) {
        setProblem(put.error);
        setBusy(null);
        return;
      }
      attachment = put.attachment;
    }

    const answer = await clockOutWith({
      description: withSummary ? said : "",
      category: withSummary ? category : "",
      client: withSummary ? client : "",
      staffFile,
      attachment,
    });
    setBusy(null);
    if (answer.error) {
      setProblem(answer.error);
      return;
    }
    onDone(withSummary && said.trim() !== "" ? said : null);
  }

  return (
    <div className="clock-summary card" role="dialog" aria-label="What did you work on">
      {problem && <p className="alert bad">{problem}</p>}

      <label className="field">
        <span>What did you work on?</span>
        <textarea
          ref={box}
          id="clock-said"
          rows={3}
          value={said}
          onChange={(e) => setSaid(e.target.value)}
          placeholder="Two job site visits and the month's coaching notes"
        />
      </label>

      <div className="row2">
        <label className="field" style={{ minWidth: 200 }}>
          <span>What kind of work</span>
          <select id="clock-category" value={category} onChange={(e) => setCategory(e.target.value)}>
            <option value="">Not said</option>
            {(choices?.categories ?? []).map((c) => (
              <option key={c.key} value={c.key}>
                {c.label}
              </option>
            ))}
          </select>
        </label>

        <label className="field" style={{ minWidth: 200 }}>
          <span>Client</span>
          <select id="clock-client" value={client} onChange={(e) => setClient(e.target.value)}>
            <option value="">Nobody in particular</option>
            {(choices?.clients ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
      </div>

      <label className="field">
        <span>A file, if there is one</span>
        <input
          id="clock-file"
          type="file"
          accept=".pdf,.doc,.docx,.jpg,.jpeg,.png,.heic,.webp"
          onChange={(e) => setFile(e.target.files?.[0] ?? null)}
        />
      </label>

      <ClockRecordingField disabled={client === ""} onPick={setRecording} />

      <div className="row2" style={{ gap: 8, marginTop: 8 }}>
        <button className="btn" type="button" disabled={busy !== null} onClick={() => void out(true)}>
          {busy ? "…" : "Clock out"}
        </button>
        <button
          className="btn ghost"
          type="button"
          disabled={busy !== null}
          onClick={() => void out(false)}
        >
          Clock out without saying
        </button>
        <button className="btn ghost" type="button" disabled={busy !== null} onClick={onCancel}>
          Stay on the clock
        </button>
      </div>
    </div>
  );
}

/**
 * The bytes, then the row that describes them.
 *
 * Browser to storage, as every other upload in the practice does, because a
 * server action has a 4.5 MB ceiling the platform will not raise and a
 * scanned day's work goes past it (check-upload-limits).
 *
 * A person's own account of their own day, so it goes in their staff file
 * under the category the practice already had for it. A recording is the
 * other case and lives in ./clock-recording.
 */
async function putTheFile({
  file,
  staffId,
}: {
  file: File;
  staffId: string;
}): Promise<{ staffFile: string | null; error: string | null }> {
  const nothing = { staffFile: null };
  if (file.size > 50 * 1024 * 1024) {
    return { ...nothing, error: `${file.name} is over 50 MB — scan it at a lower resolution.` };
  }
  const supabase = createClient();
  const ext = file.name.includes(".") ? file.name.split(".").pop() : "";
  const type = (file.type || "application/octet-stream").split(";")[0];

  const path = `staff/${staffId}/end-of-day-${crypto.randomUUID()}${ext ? `.${ext}` : ""}`;
  const { error } = await supabase.storage
    .from("staff-files")
    .upload(path, file, { contentType: type });
  if (error) return { ...nothing, error: refusal(file.name, error.message) };
  const { data: row, error: rowError } = await supabase
    .from("staff_files")
    .insert({
      staff_id: staffId,
      storage_path: path,
      filename: file.name,
      mime_type: type,
      size_bytes: file.size,
      category: "End of day report",
      uploaded_by: staffId,
    })
    .select("id")
    .single();
  if (rowError || !row) {
    await supabase.storage.from("staff-files").remove([path]);
    return { ...nothing, error: rowError?.message ?? "Your file would not take that." };
  }
  return { staffFile: row.id, error: null };
}

function refusal(name: string, message: string): string {
  const said = message.toLowerCase();
  if (said.includes("mime") || said.includes("type")) {
    return `${name} is not a file this takes — PDFs, Word files, images and recordings are.`;
  }
  return `${name} did not go up. ${message}`;
}
