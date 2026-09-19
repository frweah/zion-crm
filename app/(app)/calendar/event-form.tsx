"use client";

import { useActionState, useState } from "react";
import { saveCalendarEvent, type CalendarState } from "./actions";

const initial: CalendarState = { error: null, ok: null };

export type EventDraft = {
  crmId?: string;
  outlookId?: string;
  /** Made in Outlook: its own text is not the CRM's to change, so there is no note field. */
  fromOutlook?: boolean;
  clientId?: string | null;
  kind?: string;
  title?: string;
  /** "YYYY-MM-DDTHH:mm" in the practice's time. */
  startsAt?: string;
  minutes?: number;
  location?: string;
  note?: string;
};

/** New, or an edit of one appointment. Opens closed, as a button, until asked for. */
export function EventForm({
  draft,
  clients,
  label,
}: {
  draft: EventDraft;
  clients: { id: string; name: string }[];
  label: string;
}) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState(saveCalendarEvent, initial);
  const id = draft.crmId ?? draft.outlookId ?? "new";

  if (!open) {
    return (
      <>
        {state.ok && <div className="alert ok">{state.ok}</div>}
        <button className={draft.crmId || draft.outlookId ? "btn ghost" : "btn gold"} type="button" onClick={() => setOpen(true)} style={draft.crmId || draft.outlookId ? { padding: "2px 10px" } : undefined}>
          {label}
        </button>
      </>
    );
  }

  return (
    <form action={action} className="card" style={{ marginTop: 8 }}>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      {draft.crmId && <input type="hidden" name="crm_id" value={draft.crmId} />}
      {draft.outlookId && <input type="hidden" name="outlook_id" value={draft.outlookId} />}
      <div className="row2">
        <label className="field" style={{ flex: 2 }}>
          Title
          <input id={`ev-title-${id}`} name="title" required defaultValue={draft.title ?? ""} />
        </label>
        <label className="field">
          Client
          <select id={`ev-client-${id}`} name="client_id" defaultValue={draft.clientId ?? ""}>
            <option value="">No client</option>
            {clients.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
      </div>
      <div className="row2">
        <label className="field">
          Starts
          <input id={`ev-start-${id}`} type="datetime-local" name="starts_at" required defaultValue={draft.startsAt ?? ""} />
        </label>
        <label className="field" style={{ maxWidth: 130 }}>
          Minutes
          <input id={`ev-min-${id}`} type="number" name="minutes" min={5} step={5} defaultValue={draft.minutes ?? 60} />
        </label>
        {!draft.fromOutlook && (
          <label className="field">
            Kind
            <select id={`ev-kind-${id}`} name="kind" defaultValue={draft.kind ?? "Coaching visit"}>
              <option>Coaching visit</option>
              <option>Intake appointment</option>
              <option>Counselor call</option>
              <option>Other</option>
            </select>
          </label>
        )}
      </div>
      <label className="field">
        Where
        <input id={`ev-where-${id}`} name="location" defaultValue={draft.location ?? ""} placeholder="Office, phone, employer site" />
      </label>
      {!draft.fromOutlook && (
        <label className="field">
          Note
          <input id={`ev-note-${id}`} name="note" defaultValue={draft.note ?? ""} />
        </label>
      )}
      <div className="row2" style={{ gap: 6 }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Saving…" : draft.crmId || draft.outlookId ? "Save" : "Save and add to Outlook"}
        </button>
        <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
      <p className="lock" style={{ margin: "8px 0 0" }}>
        Times are Salt Lake City time. With a client chosen it carries their number in the title, so it is recognised
        if it is moved or renamed in Outlook.
      </p>
    </form>
  );
}
