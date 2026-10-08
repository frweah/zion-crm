"use client";

import { useActionState } from "react";
import {
  generateForm,
  markDue,
  submitAuthorization,
  closeAuthorization,
  moveStaleDate,
  recordServiceDates,
  resolveZeroHours,
  type ActionState,
} from "../actions";

const EMPTY: ActionState = { error: null, ok: null };

/**
 * The moves on one authorization (§12.4).
 *
 * Submit is the only one that is ever the obvious thing to do, so it is the
 * only one that looks like it. The rest are plain, and the ones that need a
 * reason ask for it in front of the button rather than after it - a reason
 * asked for afterwards is a field that stays empty.
 */
function Said({ state }: { state: ActionState }) {
  if (state.error) return <p className="alert bad">{state.error}</p>;
  if (state.ok) return <p className="alert ok">{state.ok}</p>;
  return null;
}

export function SubmitPacket({
  authId,
  ready,
  office,
  counselor,
  attached,
}: {
  authId: string;
  ready: boolean;
  office: string | null;
  counselor: string | null;
  attached: number;
}) {
  const [state, action, pending] = useActionState(submitAuthorization, EMPTY);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">Submit</h3>
      <p className="lock">
        {office
          ? `The packet goes to ${office}${counselor ? `, copied to ${counselor}` : ""}.`
          : "There is no billing office address on this client's record."}{" "}
        {attached === 0
          ? "Nothing is attached yet."
          : `${attached} file${attached === 1 ? "" : "s"} will go with it.`}
      </p>
      <button className="btn gold" disabled={!ready || pending || !office || attached === 0}>
        {pending ? "Sending…" : "Send the packet and mark it submitted"}
      </button>
      {!ready && (
        <p className="lock">
          The checklist above has something that stops this. Nothing is sent until it is clear.
        </p>
      )}
      <Said state={state} />
    </form>
  );
}

export function MarkDue({ authId }: { authId: string }) {
  const [state, action, pending] = useActionState(markDue, EMPTY);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">Ready to bill</h3>
      <p className="lock">Moves it onto the day&rsquo;s list. The bill-by date does this on its own overnight.</p>
      <button className="btn" disabled={pending}>
        {pending ? "…" : "Mark ready to bill"}
      </button>
      <Said state={state} />
    </form>
  );
}

export function ServiceDates({
  authId,
  start,
  end,
}: {
  authId: string;
  start: string | null;
  end: string | null;
}) {
  const [state, action, pending] = useActionState(recordServiceDates, EMPTY);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">When the work happened</h3>
      <p className="lock">
        Not when it was authorized. Dates outside the authorized period stop a submission.
      </p>
      <div className="grid">
        <label className="field">
          <span>Started</span>
          <input type="date" name="service_start" defaultValue={start ?? ""} required />
        </label>
        <label className="field">
          <span>Finished</span>
          <input type="date" name="service_end" defaultValue={end ?? ""} />
        </label>
      </div>
      <button className="btn" disabled={pending}>
        {pending ? "…" : "Record"}
      </button>
      <Said state={state} />
    </form>
  );
}

export function MoveStale({ authId, staleDate }: { authId: string; staleDate: string | null }) {
  const [state, action, pending] = useActionState(moveStaleDate, EMPTY);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">Move the date it goes stale</h3>
      <p className="lock">
        Only when USOR has extended it. The reason is kept with the record, because somebody will
        ask why this was billed after it expired.
      </p>
      <label className="field">
        <span>New date</span>
        <input type="date" name="stale_date" defaultValue={staleDate ?? ""} required />
      </label>
      <label className="field">
        <span>Why</span>
        <input name="stale_reason" required placeholder="Extension confirmed by the counselor on…" />
      </label>
      <button className="btn" disabled={pending}>
        {pending ? "…" : "Move it"}
      </button>
      <Said state={state} />
    </form>
  );
}

export function CloseIt({ authId }: { authId: string }) {
  const [state, action, pending] = useActionState(closeAuthorization, EMPTY);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">Close without billing</h3>
      <p className="lock">For work that never happened, or a month with nothing in it.</p>
      <label className="field">
        <span>Why</span>
        <input name="closed_reason" required placeholder="Client withdrew before placement" />
      </label>
      <button className="btn" disabled={pending}>
        {pending ? "…" : "Close it"}
      </button>
      <Said state={state} />
    </form>
  );
}

export function ZeroHours({ authId, month }: { authId: string; month: string }) {
  const [state, action, pending] = useActionState(resolveZeroHours, EMPTY);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">No hours logged for {month}</h3>
      <p className="lock">
        Far more often this is a month whose hours were never logged than a month with no service.
        Which was it?
      </p>
      <div className="record-actions">
        <button className="btn" name="answer" value="not logged yet" disabled={pending}>
          The hours were not logged yet
        </button>
        <button className="btn" name="answer" value="no service" disabled={pending}>
          There was no service this month
        </button>
      </div>
      <Said state={state} />
    </form>
  );
}

/**
 * The forms this authorization needs, produced from the record (§13.10).
 *
 * "Forms are generated, not filled." Each one comes up filled in from what the
 * CRM recorded as it happened - the hours, the client, the counselor, the month
 * - and what staff do is read it and sign it. There is no blank-form screen
 * anywhere, because a blank form is a request to retype what is already known.
 */
export function Forms({
  authId,
  clientId,
  outstanding,
  done,
}: {
  authId: string;
  clientId: string;
  outstanding: { id: string; usor: string; name: string }[];
  done: { id: string; usor: string; formId: string; signed: boolean }[];
}) {
  const [state, action, pending] = useActionState(generateForm, EMPTY);
  if (outstanding.length === 0 && done.length === 0) return null;

  return (
    <div className="card">
      <h2 className="h2">Its USOR forms</h2>
      {done.length > 0 && (
        <ul className="list">
          {done.map((f) => (
            <li key={f.formId}>
              <span className={f.signed ? "chip ok" : "chip warn"}>{f.signed ? "signed" : "draft"}</span>{" "}
              <a href={`/clients/${clientId}/forms/${f.formId}`} style={{ color: "var(--teal)" }}>
                {f.usor}
              </a>
            </li>
          ))}
        </ul>
      )}
      {outstanding.length === 0 ? (
        <p className="lock">Every form this service needs is on file.</p>
      ) : (
        <>
          <p className="lock">
            Each of these comes up filled in from the record and the service log. Read it against
            what you remember, then sign it.
          </p>
          <form action={action} className="record-actions">
            <input type="hidden" name="auth_id" value={authId} />
            {outstanding.map((t) => (
              <button key={t.id} className="btn" name="template_id" value={t.id} disabled={pending}>
                {pending ? "…" : `Produce ${t.usor}`}
              </button>
            ))}
          </form>
        </>
      )}
      <Said state={state} />
    </div>
  );
}
