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

export type MailRow = {
  id: string;
  subject: string;
  sent_at: string;
  direction: string;
  counterpart_email: string;
  web_link: string;
  conversation_id: string;
};

const when = (iso: string) =>
  new Date(iso).toLocaleString("en-US", {
    dateStyle: "medium",
    timeStyle: "short",
  });

function NewEvent({ clientId }: { clientId: string }) {
  const [state, action, pending] = useActionState(createClientEvent, initial);

  return (
    <div className="card">
      <h3>New appointment</h3>
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

function HoursOffer({ event, clientId }: { event: EventRow; clientId: string }) {
  const [state, action, pending] = useActionState(answerHoursPrompt, initial);

  return (
    <div className="alert" style={{ marginTop: 6 }}>
      This visit has finished. Log the service hours?
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
      <div className="row2" style={{ marginTop: 8, gap: 6 }}>
        <Link
          className="btn gold"
          href={`/clients/${clientId}?tab=authorizations&anchor=${event.id}`}
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

function RemoveEvent({ id, clientId }: { id: string; clientId: string }) {
  const [state, action, pending] = useActionState(deleteClientEvent, initial);
  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="event_id" value={id} />
      <input type="hidden" name="client_id" value={clientId} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Remove"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

function ExcludeThread({ conversationId }: { conversationId: string }) {
  const [state, action, pending] = useActionState(excludeThread, mailInitial);
  if (!conversationId) return null;
  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="conversation_id" value={conversationId} />
      <button className="btn ghost" type="submit" disabled={pending} title="Stop logging this thread">
        {pending ? "…" : "Exclude thread"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

export function CalendarTab({
  clientId,
  events,
  mail,
  myId,
  now,
}: {
  clientId: string;
  events: EventRow[];
  mail: MailRow[];
  myId: string;
  now: string;
}) {
  const upcoming = events.filter((e) => e.ends_at >= now);
  const past = events.filter((e) => e.ends_at < now);

  return (
    <>
      <NewEvent clientId={clientId} />

      <div className="card" style={{ marginTop: 14, padding: 0 }}>
        <h3 style={{ padding: "16px 16px 0" }}>Appointments</h3>
        <table className="t">
          <tbody>
            {events.length === 0 && (
              <tr>
                <td className="empty">Nothing scheduled.</td>
              </tr>
            )}
            {[...upcoming, ...past].map((e) => (
              <tr key={e.id}>
                <td>
                  <b>{e.title}</b>
                  <div style={{ fontSize: 12, color: "var(--muted)" }}>
                    {e.kind} · {when(e.starts_at)}
                    {e.location && ` · ${e.location}`}
                  </div>
                  {e.origin === "Outlook" && (
                    <span className="chip">from Outlook</span>
                  )}
                  {e.push_state === "Failed" && (
                    <div className="lock">Outlook refused it: {e.push_error}</div>
                  )}
                  {e.push_state === "Not pushed" && e.origin === "CRM" && (
                    <div className="lock">Not in Outlook — {e.push_error}</div>
                  )}
                  {e.ends_at < now &&
                    e.staff_id === myId &&
                    !e.hours_prompt_answered_at && (
                      <HoursOffer event={e} clientId={clientId} />
                    )}
                </td>
                <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                  {e.outlook_web_link && (
                    <a
                      className="btn ghost"
                      href={e.outlook_web_link}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      Open in Outlook
                    </a>
                  )}{" "}
                  {e.staff_id === myId && <RemoveEvent id={e.id} clientId={clientId} />}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginTop: 14, padding: 0 }}>
        <h3 style={{ padding: "16px 16px 0" }}>Correspondence</h3>
        <p className="sub" style={{ padding: "0 16px" }}>
          Subject, date and direction only. The contents of a message are never read into this
          system — use the link to open it in Outlook.
        </p>
        <table className="t">
          <tbody>
            {mail.length === 0 && (
              <tr>
                <td className="empty">
                  Nothing logged. Mail is matched by email address, so a message only appears here
                  if it was to or from an address on this client&apos;s record.
                </td>
              </tr>
            )}
            {mail.map((m) => (
              <tr key={m.id}>
                <td>
                  <b>{m.subject}</b>
                  <div style={{ fontSize: 12, color: "var(--muted)" }}>
                    {m.direction === "Incoming" ? "From" : "To"} {m.counterpart_email} ·{" "}
                    {when(m.sent_at)}
                  </div>
                </td>
                <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                  {m.web_link && (
                    <a
                      className="btn ghost"
                      href={m.web_link}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      Open in Outlook
                    </a>
                  )}{" "}
                  <ExcludeThread conversationId={m.conversation_id} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
