"use client";

import { useActionState, useState } from "react";
import { setSmsConsent } from "./actions";
import { fmtStamp } from "@/lib/constants";

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
};

const initial = { error: null as string | null, ok: null as string | null };

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
  canEdit,
}: {
  clientId: string;
  clientName: string;
  consent: ConsentRow | null;
  texts: TextRow[];
  canEdit: boolean;
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
        <table className="t" style={{ marginTop: 12 }}>
          <tbody>
            {texts.map((t) => (
              <tr key={t.id}>
                <td style={{ width: 130, whiteSpace: "nowrap", verticalAlign: "top" }}>
                  <span className={"chip " + (t.direction === "Incoming" ? "ok" : "")}>
                    {t.direction === "Incoming" ? "from them" : "to them"}
                  </span>
                  <div className="lock">{fmtStamp(t.sent_at ?? t.created_at)}</div>
                </td>
                <td>
                  {t.body}
                  {t.status === "Failed" && (
                    <div style={{ fontSize: 12, color: "var(--bad)" }}>
                      not delivered — {t.error}
                    </div>
                  )}
                  {t.kind === "Reminder" && <div className="lock">appointment reminder</div>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
