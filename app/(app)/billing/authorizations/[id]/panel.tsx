"use client";

import { useActionState } from "react";
import { SERVICE_TYPES, FUNDING_SOURCES } from "@/lib/constants";
import {
  generateForm,
  markDue,
  submitAuthorization,
  closeAuthorization,
  moveStaleDate,
  recordServiceDates,
  resolveZeroHours,
  recordPayment,
  correctPaymentDate,
  editAuthorization,
  setStatus,
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
      {/* The progress report is a different document for a different
          purpose, so it is offered and not assumed (owner, 30 Oct 2026). */}
      <label className="row2" style={{ gap: 6, alignItems: "center" }}>
        <input type="checkbox" name="with_report" value="1" />
        <span>Send the latest signed monthly report with it</span>
      </label>
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

/* ════════════════════════════════════════════════════════════
 * The unlock (owner, 14 Oct 2026)
 * ══════════════════════════════════════════════════════════ */

/**
 * Record what arrived.
 *
 * On anything Submitted or Due, which is the point: the flow used to want a
 * submission before it would hear about a payment, and the practice has a
 * queue of work settled long before this system existed.
 *
 * Both defaults are filled in rather than described - today, and what the
 * authorization comes to - because the common act is to glance at them and
 * press the button. The warrant number is blank and says it may stay blank.
 */
export function RecordPayment({
  authId,
  amount,
  priced,
  today,
}: {
  authId: string;
  amount: number;
  priced: boolean;
  today: string;
}) {
  const [state, action, pending] = useActionState(recordPayment, EMPTY);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">Record a payment</h3>
      <p className="lock">
        {priced
          ? "Sets this one authorization to Paid. Not the client, not its other authorizations."
          : "This authorization comes to nothing yet, so the amount has to be typed. Put the rate and hours on the record and it will price itself."}
      </p>
      <div className="grid">
        <label className="field">
          <span>Date received</span>
          <input type="date" name="received" defaultValue={today} required />
        </label>
        <label className="field">
          <span>Amount</span>
          <input
            name="amount"
            inputMode="decimal"
            defaultValue={priced ? amount.toFixed(2) : ""}
            placeholder="0.00"
            required={!priced}
          />
        </label>
      </div>
      <label className="field">
        <span>Warrant or check number</span>
        <input name="warrant" placeholder="If the stub has not arrived yet, leave this blank" />
      </label>
      <button className="btn gold" disabled={pending}>
        {pending ? "Recording…" : "Record the payment"}
      </button>
      <Said state={state} />
    </form>
  );
}

/**
 * Every field, including on a record that is already settled.
 *
 * Settled deliberately does not hide this. The owner's own test is editing
 * the number on a paid authorization and finding its PDF still attached -
 * because a corrected USOR number arriving after payment is the ordinary
 * case, not an exception.
 *
 * The reason is one field at the bottom rather than a prompt per field. The
 * database decides which changes require it, and refuses with a message that
 * names the field and both values - so nobody has to guess in advance which
 * of these is the one that asks.
 */
export function EditEverything({
  authId,
  rec,
}: {
  authId: string;
  rec: {
    number: string;
    service_type: string;
    funding_source: string;
    total_hours: number | null;
    rate_type: string;
    rate: number;
    start_date: string | null;
    end_date: string | null;
    received_on: string | null;
    bill_by: string | null;
    service_start: string | null;
    service_end: string | null;
    recipient: string | null;
    paid_on: string | null;
    paid_amount: number | null;
    warrant: string | null;
    note: string;
  };
}) {
  const [state, action, pending] = useActionState(editAuthorization, EMPTY);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h2 className="h2">The record itself</h2>
      <p className="lock">
        Everything here is Billing&rsquo;s to change. Changing the number, the authorized hours,
        the rate or the amount paid asks why, and that answer is kept with the record.
      </p>

      <div className="grid">
        <label className="field">
          <span>USOR number</span>
          <input name="number" defaultValue={rec.number} placeholder="no number yet" />
        </label>
        <label className="field">
          <span>Service</span>
          <select name="service_type" defaultValue={rec.service_type}>
            {SERVICE_TYPES.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>Funding source</span>
          <select name="funding_source" defaultValue={rec.funding_source}>
            {FUNDING_SOURCES.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="grid">
        <label className="field">
          <span>Priced as</span>
          <select name="rate_type" defaultValue={rec.rate_type}>
            <option value="Flat Fee">Flat Fee</option>
            <option value="Hourly">Hourly</option>
          </select>
        </label>
        <label className="field">
          <span>Rate</span>
          <input name="rate" inputMode="decimal" defaultValue={Number(rec.rate ?? 0).toFixed(2)} />
        </label>
        <label className="field">
          <span>Authorized hours</span>
          <input
            name="total_hours"
            inputMode="decimal"
            defaultValue={rec.total_hours == null ? "" : String(rec.total_hours)}
            placeholder="flat fee"
          />
        </label>
      </div>

      <div className="grid">
        <label className="field">
          <span>Authorized from</span>
          <input type="date" name="start_date" defaultValue={rec.start_date ?? ""} />
        </label>
        <label className="field">
          <span>Authorized to</span>
          <input type="date" name="end_date" defaultValue={rec.end_date ?? ""} />
        </label>
        <label className="field">
          <span>Received</span>
          <input type="date" name="received_on" defaultValue={rec.received_on ?? ""} required />
        </label>
        <label className="field">
          <span>Bill by</span>
          <input type="date" name="bill_by" defaultValue={rec.bill_by ?? ""} />
        </label>
      </div>

      <div className="grid">
        <label className="field">
          <span>Work started</span>
          <input type="date" name="service_start" defaultValue={rec.service_start ?? ""} />
        </label>
        <label className="field">
          <span>Work finished</span>
          <input type="date" name="service_end" defaultValue={rec.service_end ?? ""} />
        </label>
        <label className="field">
          <span>Submitted to</span>
          <input name="recipient" defaultValue={rec.recipient ?? ""} placeholder="the billing office" />
        </label>
      </div>

      {/* The money, on the same screen as everything else: a payment entered
          against the wrong month is corrected here rather than undone. */}
      <div className="grid">
        <label className="field">
          <span>Paid on</span>
          <input type="date" name="paid_on" defaultValue={rec.paid_on ?? ""} />
        </label>
        <label className="field">
          <span>Amount paid</span>
          <input
            name="paid_amount"
            inputMode="decimal"
            defaultValue={rec.paid_amount == null ? "" : Number(rec.paid_amount).toFixed(2)}
          />
        </label>
        <label className="field">
          <span>Warrant</span>
          <input name="warrant" defaultValue={rec.warrant ?? ""} />
        </label>
      </div>

      <label className="field">
        <span>Note</span>
        <textarea name="note" rows={2} defaultValue={rec.note} />
      </label>

      <label className="field">
        <span>Why, if this is a correction</span>
        <input
          name="reason"
          placeholder="USOR reissued it with a corrected number"
        />
      </label>

      <button className="btn" disabled={pending}>
        {pending ? "Saving…" : "Save the record"}
      </button>
      <Said state={state} />
    </form>
  );
}

/**
 * Setting the status, which used to be the one thing no screen offered.
 *
 * Paid is not here: it goes through Record a payment above, because an
 * authorization that says Paid with no payment behind it is the state this
 * practice already has 139 of and does not need more of. Closed asks why.
 */
export function SetStatus({ authId, status }: { authId: string; status: string }) {
  const [state, action, pending] = useActionState(setStatus, EMPTY);
  const open = ["Authorized", "Due", "Submitted"].filter((s) => s !== status);
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">Set the status</h3>
      <p className="lock">
        It is {status} now. Paid is Record a payment, so that the two cannot say different things.
      </p>
      <label className="field">
        <span>To</span>
        <select name="status" defaultValue={open[0] ?? "Closed"}>
          {open.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
          <option value="Closed">Closed</option>
        </select>
      </label>
      <label className="field">
        <span>Why (needed to close)</span>
        <input name="reason" placeholder="Client withdrew before placement" />
      </label>
      <button className="btn" disabled={pending}>
        {pending ? "…" : "Set it"}
      </button>
      <Said state={state} />
    </form>
  );
}

/**
 * Moving a payment to the month it arrived in (owner, 26 Oct 2026).
 *
 * Income by month counts on this date, so a payment typed with the wrong one
 * is income reported in the wrong month. The whole record can already be
 * edited below, but a person correcting one date should not have to open a
 * form of twenty fields to do it, and the month it would move to is worth
 * saying before the button rather than after.
 */
export function CorrectPaidDate({
  authId,
  paidOn,
  today,
}: {
  authId: string;
  paidOn: string | null;
  today: string;
}) {
  const [state, action, pending] = useActionState(correctPaymentDate, EMPTY);
  const month = paidOn
    ? new Date(`${paidOn}T00:00:00`).toLocaleDateString("en-US", { month: "long", year: "numeric" })
    : null;
  return (
    <form action={action} className="card">
      <input type="hidden" name="auth_id" value={authId} />
      <h3 className="h2">Date paid</h3>
      <p className="lock">
        {month ? `Counted as ${month} income.` : "No date, so Money is not counting it."}
      </p>
      <div className="grid">
        <label className="field">
          <span>Date paid</span>
          <input type="date" name="paid_on" defaultValue={paidOn ?? ""} max={today} required />
        </label>
        <label className="field">
          <span>Why</span>
          <input name="reason" required placeholder="The warrant is dated the 3rd, not the 30th" />
        </label>
      </div>
      <button className="btn" disabled={pending}>
        {pending ? "Moving…" : "Move it"}
      </button>
      <Said state={state} />
    </form>
  );
}
