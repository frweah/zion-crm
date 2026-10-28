"use client";

import { useActionState } from "react";
import {
  confirmWeek,
  redraftWeek,
  reopenWeek,
  saveWeekNote,
  type ReportState,
} from "./actions";

/**
 * One week, as the person who did the work reads it.
 *
 * The lines are the record and are not editable here: an hour logged wrongly
 * is fixed on Hours, an appointment on the calendar, a note on the Notes tab.
 * What belongs to this screen is the week's own sentence and the act of
 * saying the week is right, because those two things exist nowhere else.
 */

const initial: ReportState = { error: null, ok: null };

export type Line = { on: string; kind: string; text: string; hours?: number };
export type Section = { service: string; code: string; lines: Line[] };
export type WeekRow = {
  id: string;
  week_start: string;
  status: string;
  due_on: string;
  note: string;
  confirmed_by_name: string;
  content: { sections?: Section[]; withheld?: number; hours?: number } | null;
};

const stamp = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { day: "numeric", month: "short" });

export function WeekCard({
  clientId,
  week,
  canEdit,
}: {
  clientId: string;
  week: WeekRow;
  canEdit: boolean;
}) {
  const [confirmState, confirm, confirming] = useActionState(confirmWeek, initial);
  const [saveState, save, saving] = useActionState(saveWeekNote, initial);
  const [reopenState, reopen, reopening] = useActionState(reopenWeek, initial);
  const [redraftState, redraft, redrafting] = useActionState(redraftWeek, initial);

  const confirmed = week.status === "Confirmed";
  const sections = week.content?.sections ?? [];
  const withheld = week.content?.withheld ?? 0;
  const hours = week.content?.hours ?? 0;
  const lines = sections.reduce((n, s) => n + s.lines.length, 0);
  const trouble =
    confirmState.error ?? saveState.error ?? reopenState.error ?? redraftState.error;
  const went = confirmState.ok ?? saveState.ok ?? reopenState.ok ?? redraftState.ok;

  const ends = new Date(`${week.week_start}T12:00:00Z`);
  ends.setUTCDate(ends.getUTCDate() + 6);
  const span = `${stamp(week.week_start)} to ${stamp(ends.toISOString().slice(0, 10))}`;

  return (
    <article className="card" style={{ marginBottom: 14 }}>
      <div
        className="row2"
        style={{ justifyContent: "space-between", alignItems: "baseline", gap: 12 }}
      >
        <div>
          <b>{span}</b>
          <span className={"chip " + (confirmed ? "ok" : "")} style={{ marginLeft: 10 }}>
            {week.status}
          </span>
        </div>
        <span className="lock">
          {hours} hr · {lines} line{lines === 1 ? "" : "s"} · due {stamp(week.due_on)}
        </span>
      </div>

      {sections.length === 0 ? (
        <p className="empty" style={{ marginTop: 10 }}>
          No activity recorded for this week.
        </p>
      ) : (
        sections.map((s) => (
          <div key={s.service} style={{ marginTop: 14 }}>
            <h3>
              {s.service}
              {s.code !== "—" && <span className="lock"> {s.code}</span>}
            </h3>
            {s.lines.length === 0 ? (
              <p className="empty">No activity recorded.</p>
            ) : (
              <ul className="day-list">
                {s.lines.map((l, i) => (
                  <li key={`${l.on}-${i}`}>
                    <span className="lock" style={{ minWidth: 72 }}>
                      {stamp(l.on)}
                    </span>
                    <span className="day-main">{l.text}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        ))
      )}

      {withheld > 0 && (
        <p className="lock" style={{ marginTop: 10 }}>
          {withheld} note{withheld === 1 ? "" : "s"} held back, on the client record
        </p>
      )}

      {trouble && (
        <p className="alert bad" style={{ marginTop: 12 }}>
          {trouble}
        </p>
      )}
      {went && !trouble && (
        <p className="alert ok" style={{ marginTop: 12 }}>
          {went}
        </p>
      )}

      {confirmed ? (
        <div className="row2" style={{ marginTop: 12, alignItems: "baseline", gap: 12 }}>
          <span className="lock">
            {week.note ? week.note : "Confirmed with nothing added."}
          </span>
          {canEdit && (
            <form action={reopen}>
              <input type="hidden" name="week_id" value={week.id} />
              <input type="hidden" name="client_id" value={clientId} />
              <button className="btn ghost" disabled={reopening}>
                Reopen
              </button>
            </form>
          )}
        </div>
      ) : (
        <>
          <form action={confirm} style={{ marginTop: 12 }}>
            <input type="hidden" name="week_id" value={week.id} />
            <input type="hidden" name="client_id" value={clientId} />
            <label className="field">
              Where this client got to this week
              <textarea
                name="note"
                rows={3}
                defaultValue={week.note}
                readOnly={!canEdit}
                placeholder="What a counselor needs to know about the week"
              />
            </label>
            {canEdit && (
              <div className="row2" style={{ gap: 8 }}>
                <button className="btn gold" disabled={confirming}>
                  Confirm
                </button>
                <button className="btn ghost" formAction={save} disabled={saving}>
                  Save
                </button>
              </div>
            )}
          </form>
          {canEdit && (
            <form action={redraft} style={{ marginTop: 8 }}>
              <input type="hidden" name="week_id" value={week.id} />
              <input type="hidden" name="client_id" value={clientId} />
              <button className="btn ghost" disabled={redrafting}>
                Read the record again
              </button>
            </form>
          )}
        </>
      )}

      {confirmed && week.confirmed_by_name && (
        <p className="lock" style={{ marginTop: 6 }}>
          Confirmed by {week.confirmed_by_name}
        </p>
      )}
    </article>
  );
}
