"use client";

import { useActionState, useState } from "react";
import { NOTE_CATEGORIES } from "@/lib/report-shape";
import { CONTACT_KINDS } from "@/lib/recordings-shape";
import { confirmRecording, readHeldRecording, setRecordingAside } from "./recording-actions";
import type { DetailState } from "./actions";

const initial: DetailState = { error: null, ok: null };

export type RecordingRow = {
  id: string;
  attachment_id: string;
  filename: string;
  state: string;
  minutes: number | null;
  reason: string;
  transcript: string | null;
  turns: { speaker: number; at: number; text: string }[] | null;
  summary: {
    kind?: string;
    on?: string;
    present?: string;
    discussed?: string;
    decisions?: string;
    next?: string;
    question?: string;
  } | null;
  document_date: string | null;
  created_at: string;
  confirmed_at: string | null;
};

function Said({ state }: { state: DetailState }) {
  if (state.error) return <p className="alert bad">{state.error}</p>;
  if (state.ok) return <p className="alert ok">{state.ok}</p>;
  return null;
}

/** Where a recording is, in one word a person can act on. */
function stateChip(state: string) {
  if (state === "Confirmed") return <span className="chip ok">On the record</span>;
  if (state === "Drafted") return <span className="chip warn">Waiting for you</span>;
  if (state === "Read") return <span className="chip warn">Read, no draft</span>;
  if (state === "Reading") return <span className="chip">Being read</span>;
  if (state === "Waiting") return <span className="chip">Waiting to be read</span>;
  if (state === "Held") return <span className="chip bad">Held</span>;
  if (state === "Failed") return <span className="chip bad">Could not be read</span>;
  return <span className="lock">{state}</span>;
}

const minutes = (m: number | null) =>
  m === null ? null : `${m < 1 ? Math.round(m * 60) + " seconds" : Math.round(m) + " minutes"}`;

/** mm:ss, so a turn can be found in the audio. */
const at = (seconds: number) =>
  `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;

/**
 * The recordings on a client's record (item F).
 *
 * One card each, and the card says where the recording is: waiting, being
 * read, waiting for a person, on the record, or held because the month's
 * hours are spent.
 *
 * The draft is the shape a meeting note takes - the day and type of contact,
 * who was present, what was discussed, decisions, next steps and one
 * follow-up question - and every part can be changed before anything is
 * confirmed, because that is the whole point of a draft. Confirming writes a
 * contact log entry and a note; nothing about the recording is on the record
 * until it does, which is why the transcript sits behind a disclosure rather
 * than on the page - somebody scrolling a client's documents has not asked to
 * read a machine's transcript of a conversation.
 */
export function RecordingsPanel({
  clientId,
  rows,
  isAdmin,
}: {
  clientId: string;
  rows: RecordingRow[];
  isAdmin: boolean;
}) {
  if (rows.length === 0) return null;
  return (
    <section className="page-section">
      <h2 className="h2">Recordings</h2>
      {rows.map((row) => (
        <RecordingCard key={row.id} clientId={clientId} row={row} isAdmin={isAdmin} />
      ))}
    </section>
  );
}

function RecordingCard({
  clientId,
  row,
  isAdmin,
}: {
  clientId: string;
  row: RecordingRow;
  isAdmin: boolean;
}) {
  const [confirmState, confirm, confirming] = useActionState(confirmRecording, initial);
  const [asideState, aside, settingAside] = useActionState(setRecordingAside, initial);
  const [heldState, readAnyway, releasing] = useActionState(readHeldRecording, initial);
  const [open, setOpen] = useState(false);

  const draft = row.summary ?? {};
  const canDecide = row.state === "Drafted" || row.state === "Read";

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
        <b>{row.filename || "A recording"}</b>
        {stateChip(row.state)}
      </div>
      <p className="lock" style={{ marginTop: 4 }}>
        {row.created_at.slice(0, 10)}
        {minutes(row.minutes) ? ` · ${minutes(row.minutes)}` : ""}
        {row.confirmed_at ? ` · confirmed ${row.confirmed_at.slice(0, 10)}` : ""}
      </p>

      <Said state={confirmState} />
      <Said state={asideState} />
      <Said state={heldState} />

      {row.reason && row.state !== "Confirmed" && <p className="alert">{row.reason}</p>}

      {row.state === "Held" && isAdmin && (
        <form action={readAnyway}>
          <input type="hidden" name="id" value={row.id} />
          <input type="hidden" name="client_id" value={clientId} />
          <button className="btn ghost" disabled={releasing}>
            {releasing ? "…" : "Read it anyway"}
          </button>
        </form>
      )}

      {row.transcript ? (
        <details style={{ marginTop: 8 }}>
          <summary>What was said</summary>
          <div style={{ marginTop: 8 }}>
            {row.turns && row.turns.length > 0 ? (
              <table
                className="t"
                data-layout="the recording as it was read: who was speaking, when, and the words"
              >
                <thead>
                  <tr>
                    <th>At</th>
                    <th>Speaker</th>
                    <th>What they said</th>
                  </tr>
                </thead>
                <tbody>
                  {row.turns.map((turn, i) => (
                    <tr key={i}>
                      <td className="lock" style={{ whiteSpace: "nowrap" }}>
                        {at(turn.at)}
                      </td>
                      <td className="lock">{turn.speaker ? `Speaker ${turn.speaker}` : "—"}</td>
                      <td>{turn.text}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p style={{ whiteSpace: "pre-wrap" }}>{row.transcript}</p>
            )}
            <p className="lock">
              Read by Azure Speech — check names and numbers against the recording.
            </p>
          </div>
        </details>
      ) : null}

      {canDecide && (
        <>
          <form action={confirm} style={{ marginTop: 10 }}>
            <input type="hidden" name="id" value={row.id} />
            <input type="hidden" name="client_id" value={clientId} />
            <div className="row2">
              <label className="field" style={{ maxWidth: 260 }}>
                <span>Type of contact</span>
                <select name="kind" defaultValue={draft.kind ?? ""} required>
                  <option value="">Choose one</option>
                  {CONTACT_KINDS.map((k) => (
                    <option key={k} value={k}>
                      {k}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field" style={{ maxWidth: 200 }}>
                <span>Date</span>
                <input
                  type="date"
                  name="on"
                  defaultValue={row.document_date ?? row.created_at.slice(0, 10)}
                  required
                />
              </label>
            </div>
            <label className="field">
              <span>Who was present</span>
              <input name="present" defaultValue={draft.present ?? ""} required />
            </label>
            <label className="field">
              <span>What was discussed</span>
              <textarea name="discussed" rows={2} defaultValue={draft.discussed ?? ""} required />
            </label>
            <label className="field">
              <span>Decisions</span>
              <textarea name="decisions" rows={2} defaultValue={draft.decisions ?? ""} />
            </label>
            <label className="field">
              <span>Next steps</span>
              <textarea name="next" rows={2} defaultValue={draft.next ?? ""} />
            </label>
            <label className="field">
              <span>Follow-up question</span>
              <input name="question" defaultValue={draft.question ?? ""} />
            </label>
            <label className="field" style={{ maxWidth: 260 }}>
              <span>What it is about</span>
              <select name="category" defaultValue="General progress">
                {NOTE_CATEGORIES.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </label>
            <button className="btn" disabled={confirming}>
              {confirming ? "…" : "Confirm it"}
            </button>
            {!open && (
              <button
                type="button"
                className="btn ghost"
                style={{ marginLeft: 6 }}
                onClick={() => setOpen(true)}
              >
                Do not use it
              </button>
            )}
          </form>

          {open && (
            <form action={aside} style={{ marginTop: 10 }}>
              <input type="hidden" name="id" value={row.id} />
              <input type="hidden" name="client_id" value={clientId} />
              <label className="field">
                <span>Why it is not going on the record</span>
                <input name="reason" required placeholder="Wrong client — it is the next appointment" />
              </label>
              <button className="btn ghost" disabled={settingAside}>
                Do not use it
              </button>
            </form>
          )}
        </>
      )}

      {row.state === "Confirmed" && row.summary && (
        <div style={{ marginTop: 8 }}>
          <p>
            <b>
              {row.summary.kind}
              {row.summary.on ? `, ${row.summary.on}` : ""}
            </b>
          </p>
          {row.summary.present ? <p className="lock">Present: {row.summary.present}</p> : null}
          {row.summary.discussed ? <p>{row.summary.discussed}</p> : null}
          {row.summary.decisions ? <p>{row.summary.decisions}</p> : null}
          {row.summary.next ? <p className="lock">Next: {row.summary.next}</p> : null}
          {row.summary.question ? <p className="lock">Ask next time: {row.summary.question}</p> : null}
        </div>
      )}
    </div>
  );
}
