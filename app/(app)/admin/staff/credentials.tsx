"use client";

import { useActionState, useState } from "react";
import {
  recordCredential,
  setTransportsClients,
  logCeHours,
  type CredentialState,
} from "./credential-actions";

const initial: CredentialState = { error: null, ok: null };

export type CredentialType = {
  key: string;
  label: string;
  detail: string;
  kind: string;
  expires: boolean;
  months_valid: number | null;
  applies_to: string;
  hours_target: number | null;
};

export type StatusRow = {
  staff_id: string;
  type_key: string;
  label: string;
  kind: string;
  required: boolean;
  state: string;
  reference: string | null;
  issued_on: string | null;
  expires_on: string | null;
  days_left: number | null;
  hours_this_year: number;
  hours_target: number | null;
};

const TONE: Record<string, string> = {
  Expired: "bad",
  Missing: "bad",
  Expiring: "warn",
  Outstanding: "warn",
  Valid: "ok",
  Met: "ok",
};

/**
 * What somebody holds, and what they are short of.
 *
 * The state comes from the database rather than being worked out here: the
 * staff list, a person's own page and anything added later have to agree
 * about whether a CPR card has run out, and the only way to guarantee that is
 * for none of them to decide it.
 */
export function StaffCredentials({
  staffId,
  staffName,
  rows,
  types,
  transports,
}: {
  staffId: string;
  staffName: string;
  rows: StatusRow[];
  types: CredentialType[];
  transports: boolean;
}) {
  const [state, action, pending] = useActionState(recordCredential, initial);
  const [transportState, transportAction, savingTransport] = useActionState(
    setTransportsClients,
    initial,
  );
  const [adding, setAdding] = useState<string | null>(null);

  const problems = rows.filter((r) =>
    ["Expired", "Missing", "Expiring", "Outstanding"].includes(r.state),
  ).length;

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <div>
          <h3 style={{ margin: 0 }}>{staffName}</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            {problems === 0 ? (
              "Everything they need is on file and current."
            ) : (
              <b style={{ color: "var(--bad)" }}>
                {problems} {problems === 1 ? "thing needs" : "things need"} attention
              </b>
            )}
          </p>
        </div>

        <form action={transportAction}>
          <input type="hidden" name="staff_id" value={staffId} />
          <input type="hidden" name="transports" value={transports ? "no" : "yes"} />
          <button className="btn ghost" type="submit" disabled={savingTransport}>
            {transports ? "Does not transport clients" : "Transports clients"}
          </button>
        </form>
      </div>

      {transports && (
        <p className="lock" style={{ margin: "6px 0 0" }}>
          Carries clients, so a licence and insurance are required as well.
        </p>
      )}

      {state.error && <div className="alert bad" style={{ marginTop: 10 }}>{state.error}</div>}
      {state.ok && <div className="alert ok" style={{ marginTop: 10 }}>{state.ok}</div>}
      {transportState.error && (
        <div className="alert bad" style={{ marginTop: 10 }}>{transportState.error}</div>
      )}
      {transportState.ok && (
        <div className="alert ok" style={{ marginTop: 10 }}>{transportState.ok}</div>
      )}

      <table className="t" style={{ marginTop: 10 }}>
        <tbody>
          {rows.map((r) => (
            <tr key={r.type_key}>
              <td style={{ width: 210 }}>
                {r.label}
                {!r.required && <div className="lock">not required of them</div>}
              </td>
              <td style={{ width: 130 }}>
                <span className={"chip " + (TONE[r.state] ?? "")}>{r.state}</span>
              </td>
              <td>
                {r.kind === "hours" ? (
                  <>
                    {Number(r.hours_this_year)} of {Number(r.hours_target ?? 0)} hours this year
                  </>
                ) : r.expires_on ? (
                  <>
                    {r.state === "Expired" ? "ran out" : "until"} {r.expires_on}
                    {r.days_left !== null && r.days_left >= 0 && (
                      <span className="lock"> · {r.days_left} days</span>
                    )}
                    {r.reference && <div className="lock">{r.reference}</div>}
                  </>
                ) : r.issued_on ? (
                  <>
                    issued {r.issued_on}
                    {r.reference && <div className="lock">{r.reference}</div>}
                  </>
                ) : (
                  <span className="lock">nothing on file</span>
                )}
              </td>
              <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                {r.kind !== "hours" && (
                  <button
                    className="btn ghost"
                    type="button"
                    style={{ padding: "2px 10px" }}
                    onClick={() => setAdding(adding === r.type_key ? null : r.type_key)}
                  >
                    {adding === r.type_key
                      ? "Cancel"
                      : r.state === "Missing"
                        ? "Record"
                        : "Renew"}
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {adding && (
        <form action={action} style={{ marginTop: 10 }}>
          <input type="hidden" name="staff_id" value={staffId} />
          <input type="hidden" name="type_key" value={adding} />
          <div className="row2">
            <label className="field" style={{ maxWidth: 170 }}>
              Issued
              <input type="date" name="issued_on" />
            </label>
            <label className="field" style={{ maxWidth: 170 }}>
              Expires
              <input type="date" name="expires_on" />
              <span className="lock">
                {types.find((t) => t.key === adding)?.expires
                  ? `Usually ${types.find((t) => t.key === adding)?.months_valid ?? "—"} months`
                  : "This one does not expire"}
              </span>
            </label>
            <label className="field" style={{ maxWidth: 200 }}>
              Reference
              <input name="reference" placeholder="Certificate number" />
              <span className="lock">Not a full licence number.</span>
            </label>
            <label className="field" style={{ flex: 2 }}>
              Note
              <input name="note" />
            </label>
            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Record it"}
            </button>
          </div>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            Recorded as verified by you, now. A renewal is added beside the old one rather than
            replacing it — the question &ldquo;were they covered in March&rdquo; needs both.
          </p>
        </form>
      )}
    </div>
  );
}

/**
 * Logging hours somebody has done.
 *
 * On the person's own Paperwork screen as well as here, because the person
 * who sat through the training is the one who knows what it was.
 */
export function CeForm({
  staffId,
  today,
  forSomebodyElse,
}: {
  staffId: string;
  today: string;
  forSomebodyElse?: boolean;
}) {
  const [state, action, pending] = useActionState(logCeHours, initial);

  return (
    <form action={action}>
      <input type="hidden" name="staff_id" value={staffId} />
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      <div className="row2">
        <label className="field" style={{ maxWidth: 170 }}>
          When
          <input type="date" name="on_date" max={today} defaultValue={today} required />
        </label>
        <label className="field" style={{ maxWidth: 110 }}>
          Hours
          <input type="number" name="hours" step="0.25" min="0.25" max="40" required />
        </label>
        <label className="field" style={{ flex: 2 }}>
          What it was about
          <input name="topic" required placeholder="Supported employment: natural supports" />
        </label>
        <label className="field" style={{ maxWidth: 200 }}>
          Provider
          <input name="provider" placeholder="USOR, APSE, a college" />
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Log"}
        </button>
      </div>
      {forSomebodyElse && (
        <p className="lock" style={{ margin: "8px 0 0" }}>
          Logged against them, recorded as entered by you.
        </p>
      )}
    </form>
  );
}
