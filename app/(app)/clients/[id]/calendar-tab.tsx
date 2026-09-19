"use client";

import { useActionState } from "react";
import Link from "next/link";
import {
  createClientEvent,
  deleteClientEvent,
  answerHoursPrompt,
  type EventState,
} from "./calendar-actions";
import { excludeThread, type MailState } from "./mail-actions";
import { TaskToggle, type TaskRow } from "./tasks-tab";

const initial: EventState = { error: null, ok: null };
const mailInitial: MailState = { error: null, ok: null };

export type EventRow = {
  id: string;
  kind: string;
  title: string;
  starts_at: string;
  ends_at: string;
  location: string;
  origin: string;
  outlook_web_link: string | null;
  push_state: string;
  push_error: string;
  hours_prompt_answered_at: string | null;
  staff_id: string;
};

const when = (iso: string) =>
  new Date(iso).toLocaleString("en-US", {
    dateStyle: "medium",
    timeStyle: "short",
  });

export function NewEvent({ clientId }: { clientId: string }) {
  const [state, action, pending] = useActionState(createClientEvent, initial);

  return (
    <div style={{ marginTop: 10 }}>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <input type="hidden" name="client_id" value={clientId} />
        <div className="row2">
          <label className="field">
            Kind
            <select name="kind" defaultValue="Coaching visit">
              <option>Coaching visit</option>
              <option>Intake appointment</option>
              <option>Counselor call</option>
              <option>Other</option>
            </select>
          </label>
          <label className="field" style={{ flex: 2 }}>
            Title
            <input name="title" required placeholder="What it is" />
          </label>
        </div>
        <div className="row2">
          <label className="field">
            Starts
            <input type="datetime-local" name="starts_at" required />
          </label>
          <label className="field">
            Minutes
            <input type="number" name="minutes" min={5} step={5} defaultValue={60} />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Where
            <input name="location" placeholder="Office, phone, employer site" />
          </label>
        </div>
        <label className="field">
          Note
          <input name="note" />
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save and add to Outlook"}
        </button>
        <p className="lock" style={{ marginBottom: 0 }}>
          It goes into your own Outlook calendar, tagged with this client&apos;s number so it can
          be recognised if you move or rename it there.
        </p>
      </form>
    </div>
  );
}

export function HoursOffer({ event, clientId }: { event: EventRow; clientId: string }) {
  const [state, action, pending] = useActionState(answerHoursPrompt, initial);

  return (
    <div className="alert" style={{ marginTop: 6 }}>
      This visit has finished. Log the service hours?
      {state.error && <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</div>}
      <div className="row2" style={{ marginTop: 8, gap: 6 }}>
        <Link
          className="btn gold"
          href={`/clients/${clientId}?tab=billing&anchor=${event.id}`}
          style={{ textDecoration: "none" }}
        >
          Log hours
        </Link>
        <form action={action} style={{ display: "inline" }}>
          <input type="hidden" name="event_id" value={event.id} />
          <input type="hidden" name="client_id" value={clientId} />
          <button className="btn ghost" type="submit" disabled={pending}>
            {pending ? "…" : "Not this one"}
          </button>
        </form>
      </div>
      <p className="lock" style={{ margin: "8px 0 0" }}>
        Nothing is logged until you enter it. A calendar entry says an appointment was scheduled,
        not that it happened or how long it ran.
      </p>
    </div>
  );
}

export function RemoveEvent({ id, clientId }: { id: string; clientId: string }) {
  const [state, action, pending] = useActionState(deleteClientEvent, initial);
  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="event_id" value={id} />
      <input type="hidden" name="client_id" value={clientId} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Remove"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</div>}
    </form>
  );
}

export function ExcludeThread({ conversationId }: { conversationId: string }) {
  const [state, action, pending] = useActionState(excludeThread, mailInitial);
  if (!conversationId) return null;
  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="conversation_id" value={conversationId} />
      <button className="btn ghost" type="submit" disabled={pending} title="Stop logging this thread">
        {pending ? "…" : "Exclude thread"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</div>}
    </form>
  );
}

/**
 * The top of Activity: what is still to happen.
 *
 * Open tasks, appointments not yet over, and your own finished visits still
 * waiting to be asked about their hours. These used to be the Tasks and
 * Calendar & mail tabs. What has already happened - tasks done, past
 * appointments, mail - is in the feed below, in one order with everything else.
 */
export function ComingUp({
  clientId,
  tasks,
  events,
  myId,
  now,
}: {
  clientId: string;
  tasks: TaskRow[];
  events: EventRow[];
  myId: string;
  now: string;
}) {
  const upcoming = events
    .filter((e) => e.ends_at >= now)
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  const waitingForHours = events.filter(
    (e) => e.ends_at < now && e.staff_id === myId && !e.hours_prompt_answered_at,
  );

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <h3 style={{ marginTop: 0 }}>Coming up</h3>

      {tasks.length === 0 && upcoming.length === 0 && waitingForHours.length === 0 && (
        <p className="sub" style={{ margin: 0 }}>
          No open tasks and nothing scheduled.
        </p>
      )}

      {tasks.map((t) => (
        <TaskToggle key={t.id} clientId={clientId} task={t} />
      ))}

      {upcoming.map((e) => (
        <div key={e.id} className="taskrow" style={{ alignItems: "flex-start" }}>
          <span className="chip">{e.kind}</span>
          <span style={{ flex: 1 }}>
            <b>{e.title}</b>
            <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>
              {when(e.starts_at)}
              {e.location && ` · ${e.location}`}
              {e.origin === "Outlook" && " · from Outlook"}
            </div>
            {e.push_state === "Failed" && <div className="lock">Outlook refused it: {e.push_error}</div>}
            {e.push_state === "Not pushed" && e.origin === "CRM" && (
              <div className="lock">Not in Outlook — {e.push_error}</div>
            )}
          </span>
          <span style={{ whiteSpace: "nowrap" }}>
            {e.outlook_web_link && (
              <a className="btn ghost" href={e.outlook_web_link} target="_blank" rel="noopener noreferrer">
                Open in Outlook
              </a>
            )}{" "}
            {e.staff_id === myId && <RemoveEvent id={e.id} clientId={clientId} />}
          </span>
        </div>
      ))}

      {waitingForHours.map((e) => (
        <div key={e.id} style={{ marginTop: 8 }}>
          <b>{e.title}</b>{" "}
          <span className="lock">
            {e.kind} · {when(e.starts_at)}
          </span>
          <HoursOffer event={e} clientId={clientId} />
        </div>
      ))}

      <details style={{ marginTop: 12 }}>
        <summary style={{ cursor: "pointer", fontWeight: 600, fontSize: "var(--text-md)" }}>New appointment</summary>
        <NewEvent clientId={clientId} />
      </details>
    </div>
  );
}
