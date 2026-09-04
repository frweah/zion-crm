"use client";

import { useActionState } from "react";
import {
  addCounselor,
  logContact,
  requestHours,
  updateHoursRequest,
  type CounselorState,
} from "./actions";
import { today } from "@/lib/constants";

const initial: CounselorState = { error: null, ok: null };

const METHODS = [
  "Phone call",
  "Email",
  "Fax",
  "In person",
  "Report sent",
  "Invoice sent",
  "Authorization received",
];

const RESPONSES = ["Pending", "Approved", "Partially approved", "Denied"];

type Option = { id: string; name: string };

function Message({ state }: { state: CounselorState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export function LogContactForm({
  counselors,
  clients,
}: {
  counselors: Option[];
  clients: Option[];
}) {
  const [state, action, pending] = useActionState(logContact, initial);

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <Message state={state} />
      <form action={action}>
        <div className="row2">
          <label className="field">
            Counselor
            <select name="counselor_id" required defaultValue="">
              <option value="">— choose —</option>
              {counselors.map((k) => (
                <option key={k.id} value={k.id}>
                  {k.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            Client
            <select name="client_id" defaultValue="">
              <option value="">— general —</option>
              {clients.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Date
            <input name="date" type="date" max={today()} defaultValue={today()} />
          </label>
          <label className="field">
            Method
            <select name="method" defaultValue="Phone call">
              {METHODS.map((m) => (
                <option key={m}>{m}</option>
              ))}
            </select>
          </label>
        </div>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Topic
            <input name="topic" required />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Outcome
            <input name="outcome" />
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Follow up by
            <input name="follow_up" type="date" />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Log contact"}
          </button>
        </div>
        <p className="lock" style={{ margin: "8px 0 0" }}>
          A follow-up date puts this on your dashboard when it comes due.
        </p>
      </form>
    </div>
  );
}

export function AddCounselorForm() {
  const [state, action, pending] = useActionState(addCounselor, initial);

  return (
    <div className="card">
      <h3>Add counselor</h3>
      <Message state={state} />
      <form action={action}>
        <div className="row2">
          <label className="field">
            Name
            <input name="name" required />
          </label>
          <label className="field">
            Agency
            <input name="agency" defaultValue="Utah State Office of Rehabilitation" />
          </label>
          <label className="field">
            Phone
            <input name="phone" />
          </label>
          <label className="field">
            Fax
            <input name="fax" />
          </label>
          <label className="field">
            Email
            <input name="email" type="email" />
          </label>
        </div>
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" style={{ flex: 2 }}>
            Office
            <input name="office" />
          </label>
          <label className="field">
            Notes
            <input name="notes" />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Adding…" : "Add"}
          </button>
        </div>
      </form>
    </div>
  );
}

export function RequestHoursForm({
  counselors,
  authorizations,
}: {
  counselors: Option[];
  authorizations: Option[];
}) {
  const [state, action, pending] = useActionState(requestHours, initial);

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <Message state={state} />
      <form action={action}>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            Authorization
            <select name="auth_id" required defaultValue="">
              <option value="">— choose —</option>
              {authorizations.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            Counselor
            <select name="counselor_id" defaultValue="">
              <option value="">— choose —</option>
              {counselors.map((k) => (
                <option key={k.id} value={k.id}>
                  {k.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Date requested
            <input name="date" type="date" defaultValue={today()} />
          </label>
          <label className="field" style={{ maxWidth: 110 }}>
            Hours
            <input name="hours" type="number" step="0.25" required />
          </label>
        </div>
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" style={{ flex: 3 }}>
            Reason
            <input name="reason" required />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Submit request"}
          </button>
        </div>
      </form>
    </div>
  );
}

export type HoursRequestRow = {
  id: string;
  date: string;
  hours: number | null;
  reason: string;
  response: string;
  approved: number | null;
  approved_date: string | null;
  auth_number: string;
  client_name: string;
  counselor_name: string;
};

export function HoursRequestRowForm({ request }: { request: HoursRequestRow }) {
  const [state, action, pending] = useActionState(updateHoursRequest, initial);
  const settled = request.response !== "Pending" && request.response !== "Denied";

  return (
    <tr>
      <td>{request.date}</td>
      <td>{request.auth_number}</td>
      <td>{request.client_name}</td>
      <td>{request.hours}</td>
      <td>{request.reason}</td>
      <td>{request.counselor_name}</td>
      <td colSpan={2}>
        <form action={action} className="row2" style={{ gap: 6 }}>
          <input type="hidden" name="request_id" value={request.id} />
          <select name="response" defaultValue={request.response} style={{ maxWidth: 150 }}>
            {RESPONSES.map((r) => (
              <option key={r}>{r}</option>
            ))}
          </select>
          <input
            name="approved"
            type="number"
            step="0.25"
            placeholder="hrs"
            defaultValue={request.approved ?? ""}
            style={{ maxWidth: 80 }}
          />
          <input
            name="approved_date"
            type="date"
            defaultValue={request.approved_date ?? ""}
            style={{ maxWidth: 150 }}
          />
          <button className="btn ghost" type="submit" disabled={pending}>
            {pending ? "…" : "Save"}
          </button>
        </form>
        {state.error && (
          <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>
        )}
        {!settled && request.response !== "Pending" && (
          <div className="lock">Denied requests keep no approved hours.</div>
        )}
      </td>
    </tr>
  );
}
