"use client";

import { useActionState, useState } from "react";
import { setSmsConsent } from "./actions";
import { retryText, assignTextThread } from "./text-actions";
import { senderOf, statusOf } from "@/lib/text-rows";
import { fmtStamp } from "@/lib/constants";
import { DataTable } from "../../data-table";

export type ConsentRow = {
  state: string | null;
  consented_phone: string | null;
  client_phone: string | null;
  method: string | null;
  since: string | null;
  can_text: boolean | null;
};

export type TextRow = {
  id: string;
  direction: string;
  body: string;
  kind: string;
  status: string;
  error: string;
  sent_at: string | null;
  created_at: string;
  /** The picture, where there is one. Referenced, never copied (0280). */
  media_url: string | null;
  /** Set once the provider has taken it, which is what stops a retry. */
  provider_message_id: string | null;
  created_by: string | null;
};

const initial = { error: null as string | null, ok: null as string | null };

/**
 * Retry, on a text that was given up on.
 *
 * It re-sends the same row. The database refuses it if the provider ever took
 * the message, so the worst this button can do is tell somebody it will not
 * do it (0280).
 */
function RetryText({ id, clientId }: { id: string; clientId: string }) {
  const [state, action, pending] = useActionState(retryText, initial);
  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="text_id" value={id} />
      <input type="hidden" name="client_id" value={clientId} />
      <button type="submit" className="linkish" disabled={pending} style={{ marginLeft: 6 }}>
        {pending ? "Sending…" : "Retry"}
      </button>
      {state.error && <span className="lock"> {state.error}</span>}
    </form>
  );
}

/**
 * Texting, on the client's record.
 *
 * The panel exists to make one thing obvious at a glance: whether we may text
 * this person. Everything else here — the history, the number consent was
 * given for, who recorded it — is there for the day somebody asks why we did.
 */
export function TextingPanel({
  clientId,
  clientName,
  consent,
  texts,
  senders,
  canEdit,
  thread,
  staff,
}: {
  clientId: string;
  clientName: string;
  consent: ConsentRow | null;
  texts: TextRow[];
  /** Who each sender is, by id, so a row can say who sent it (1a). */
  senders: Record<string, string>;
  canEdit: boolean;
  /** The texting thread, once there is one to assign (1e). */
  thread: { id: string; assigned_staff_id: string | null } | null;
  staff: { id: string; name: string }[];
}) {
  const [state, action, pending] = useActionState(setSmsConsent, initial);
  const [asking, setAsking] = useState(false);

  const canText = Boolean(consent?.can_text);
  const has = Boolean(consent?.state);
  const numberChanged =
    consent?.state === "Granted" &&
    consent.consented_phone &&
    consent.consented_phone !== consent.client_phone;

  const first = clientName.trim().split(/\s+/)[0] || "this client";

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <div>
          <h3 style={{ margin: 0 }}>Texting</h3>
          {thread && (
            <AssignThread
              conversationId={thread.id}
              clientId={clientId}
              assignedTo={thread.assigned_staff_id}
              staff={staff}
              canEdit={canEdit}
            />
          )}
          <p className="sub" style={{ margin: "4px 0 0" }}>
            {canText ? (
              <>
                <b style={{ color: "var(--lime)" }}>{first} has agreed to be texted</b> at{" "}
                {consent?.consented_phone}. Appointment reminders go out the day before.
              </>
            ) : consent?.state === "Withdrawn" ? (
              <>
                <b style={{ color: "var(--bad)" }}>Consent withdrawn</b>
                {consent.since && ` on ${consent.since.slice(0, 10)}`}. Nothing is sent to{" "}
                {first}.
              </>
            ) : !consent?.client_phone ? (
              <>No usable phone number on this record, so there is nothing to consent to.</>
            ) : (
              <>
                No consent recorded, so <b>nothing is sent</b>. Ask {first} whether they would
                like reminders, then record what they said.
              </>
            )}
          </p>
          {numberChanged && (
            <div className="alert bad" style={{ marginTop: 8 }}>
              Consent was given for {consent?.consented_phone}, and the record now holds{" "}
              {consent?.client_phone ?? "no usable number"}. Nothing will be sent until consent is
              recorded for the new number.
            </div>
          )}
        </div>

        {canEdit && consent?.client_phone && (
          <div className="row2" style={{ gap: 6 }}>
            {canText ? (
              <form action={action}>
                <input type="hidden" name="id" value={clientId} />
                <input type="hidden" name="state" value="Withdrawn" />
                <input type="hidden" name="note" value="Withdrawn by staff" />
                <button className="btn ghost" type="submit" disabled={pending}>
                  {pending ? "…" : "Withdraw consent"}
                </button>
              </form>
            ) : (
              <button className="btn" type="button" onClick={() => setAsking(!asking)}>
                {asking ? "Cancel" : "Record consent"}
              </button>
            )}
          </div>
        )}
      </div>

      {state.error && <div className="alert bad" style={{ marginTop: 10 }}>{state.error}</div>}
      {state.ok && <div className="alert ok" style={{ marginTop: 10 }}>{state.ok}</div>}

      {asking && canEdit && (
        <form action={action} style={{ marginTop: 12 }}>
          <input type="hidden" name="id" value={clientId} />
          <input type="hidden" name="state" value="Granted" />
          <div className="row2">
            <label className="field" style={{ maxWidth: 200 }}>
              How it was given
              <select name="method" defaultValue="Verbal">
                <option>Verbal</option>
                <option>Written</option>
                <option>Intake form</option>
              </select>
            </label>
            <label className="field" style={{ flex: 3 }}>
              What was said, and when
              <input
                name="note"
                required
                placeholder="Asked at intake on 3 March; said yes to appointment reminders"
              />
            </label>
            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Record it"}
            </button>
          </div>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            This note is the whole record of consent. Write what would answer the question two
            years from now — consent is for {consent?.client_phone}, and it does not follow them
            to a new number.
          </p>
        </form>
      )}

      {has && !asking && (
        <p className="lock" style={{ margin: "10px 0 0" }}>
          {consent?.state} since {consent?.since ? fmtStamp(consent.since) : "—"}
          {consent?.method && ` · ${consent.method.toLowerCase()}`}. A client can stop them at any
          time by replying STOP, which withdraws consent by itself.
        </p>
      )}

      {texts.length > 0 && (
        <div style={{ marginTop: 12 }}>
          <DataTable
            label="texts"
            columns={[
              { key: "when", label: "When", width: 130 },
              { key: "body", label: "Message" },
            ]}
            rows={texts.map((t) => ({
              key: t.id,
              sort: { when: t.sent_at ?? t.created_at, body: t.body },
              cells: {
                when: (
                  <span style={{ whiteSpace: "nowrap" }}>
                    {/* Direction and who, on every row (1a). "In" and "Out"
                        rather than the old "from them" / "to them", because
                        the same two words have to read the same on the
                        client's record and in the Inbox. */}
                    <span className={"chip " + (t.direction === "Incoming" ? "ok" : "")}>
                      {t.direction === "Incoming" ? "In" : "Out"}
                    </span>
                    <div className="lock">{senderOf(t, clientName, senders)}</div>
                    <div className="lock">{fmtStamp(t.sent_at ?? t.created_at)}</div>
                  </span>
                ),
                body: (
                  <>
                    {t.body}
                    {/* The picture, where there is one (1b). The provider's
                        URL, so it keeps their retention and there is not a
                        second copy of a client's photograph here. */}
                    {t.media_url && (
                      <div style={{ marginTop: 4 }}>
                        <a href={t.media_url} target="_blank" rel="noopener noreferrer">
                          {/* eslint-disable-next-line @next/next/no-img-element */}
                          <img
                            src={t.media_url}
                            alt="Picture sent with this text"
                            style={{ maxWidth: 180, maxHeight: 180, borderRadius: "var(--radius)" }}
                          />
                        </a>
                      </div>
                    )}
                    {(statusOf(t) === "Failed" || statusOf(t) === "Not delivered") && (
                      <div style={{ fontSize: "var(--text-sm)", color: "var(--bad)" }}>
                        {statusOf(t) === "Failed" ? "refused" : "not delivered"} —{" "}
                        {t.error || "no status received from GHL"}
                        {canEdit && !t.provider_message_id && <RetryText id={t.id} clientId={clientId} />}
                      </div>
                    )}
                    {statusOf(t) === "Queued" && <div className="lock">sending…</div>}
                    {t.kind === "Reminder" && <div className="lock">appointment reminder</div>}
                  </>
                ),
              },
            }))}
            empty="No texts have been sent or received."
          />
        </div>
      )}
    </div>
  );
}

/**
 * Who is answering this thread (1e).
 *
 * Shown whether or not the person looking may change it: knowing who is
 * answering is the point, and a name with no control beside it is still the
 * answer. The Inbox filters on the same field, so "Mine" there and this line
 * cannot disagree.
 */
function AssignThread({
  conversationId,
  clientId,
  assignedTo,
  staff,
  canEdit,
}: {
  conversationId: string;
  clientId: string;
  assignedTo: string | null;
  staff: { id: string; name: string }[];
  canEdit: boolean;
}) {
  const [state, action, pending] = useActionState(assignTextThread, initial);
  const who = assignedTo ? (staff.find((s) => s.id === assignedTo)?.name ?? "somebody who has left") : "nobody";

  if (!canEdit) {
    return (
      <p className="lock" style={{ margin: "4px 0 0" }}>
        Answered by {who}
      </p>
    );
  }

  return (
    <form action={action} className="row2" style={{ gap: 6, alignItems: "center", margin: "6px 0 0" }}>
      <input type="hidden" name="conversation_id" value={conversationId} />
      <input type="hidden" name="client_id" value={clientId} />
      <label className="lock" htmlFor={`answered-by-${conversationId}`}>
        Answered by
      </label>
      <select
        id={`answered-by-${conversationId}`}
        name="staff_id"
        defaultValue={assignedTo ?? ""}
        style={{ maxWidth: 170 }}
      >
        <option value="">Nobody</option>
        {staff.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </select>
      <button className="btn ghost" type="submit" disabled={pending} style={{ padding: "2px 10px" }}>
        {pending ? "…" : "Change"}
      </button>
      {state.error && <span className="lock">{state.error}</span>}
    </form>
  );
}
