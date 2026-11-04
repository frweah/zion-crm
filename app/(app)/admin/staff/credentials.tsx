"use client";

import { useActionState, useState } from "react";
import {
  recordCredential,
  verifyCredential,
  setTransportsClients,
  setDeliversServices,
  setCredentialRequirement,
  logCeHours,
  type CredentialState,
} from "./credential-actions";
import { DataTable } from "../../data-table";
import { OpenButton } from "./documents";

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

/** An Admin saying this person does or does not need one, whatever the default says. */
export type CredentialDecision = {
  type_key: string;
  required: boolean;
  reason: string;
  decided_at: string;
};

export type StatusRow = {
  staff_id: string;
  type_key: string;
  label: string;
  kind: string;
  required: boolean;
  state: string;
  credential_id?: string | null;
  file_id?: string | null;
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
  "Awaiting check": "warn",
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
  delivers,
  decided,
  readOnly,
}: {
  staffId: string;
  staffName: string;
  rows: StatusRow[];
  types: CredentialType[];
  transports: boolean;
  /** Delivers job coaching or supported employment, which is what ACRE is for. */
  delivers: boolean;
  decided: CredentialDecision[];
  /** Somebody inactive: what they held is shown, and nothing can be recorded or changed. */
  readOnly?: boolean;
}) {
  const [state, action, pending] = useActionState(recordCredential, initial);
  const [transportState, transportAction, savingTransport] = useActionState(
    setTransportsClients,
    initial,
  );
  const [deliverState, deliverAction, savingDeliver] = useActionState(setDeliversServices, initial);
  const decidedBy = new Map(decided.map((d) => [d.type_key, d]));
  const [adding, setAdding] = useState<string | null>(null);

  const [verifyState, verifyAction, verifying] = useActionState(verifyCredential, initial);
  const problems = rows.filter((r) =>
    ["Expired", "Missing", "Awaiting check", "Expiring", "Outstanding"].includes(r.state),
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

        {!readOnly && (
          <div className="row2" style={{ gap: 6, flexWrap: "wrap" }}>
            <form action={transportAction}>
              <input type="hidden" name="staff_id" value={staffId} />
              <input type="hidden" name="transports" value={transports ? "no" : "yes"} />
              <button className="btn ghost" type="submit" disabled={savingTransport}>
                {transports ? "Does not transport clients" : "Transports clients"}
              </button>
            </form>
            {/* What ACRE and the yearly hours are actually for. It was asked of
                everybody, so the bookkeeper was being chased for a job
                coaching certificate (0288). */}
            <form action={deliverAction}>
              <input type="hidden" name="staff_id" value={staffId} />
              <input type="hidden" name="delivers" value={delivers ? "no" : "yes"} />
              <button className="btn ghost" type="submit" disabled={savingDeliver}>
                {delivers ? "Does not deliver job coaching" : "Delivers job coaching"}
              </button>
            </form>
          </div>
        )}
      </div>

      {transports && (
        <p className="lock" style={{ margin: "6px 0 0" }}>
          Carries clients, so a licence and insurance are required as well.
        </p>
      )}
      {delivers && (
        <p className="lock" style={{ margin: "6px 0 0" }}>
          Delivers job coaching, so ACRE and the yearly hours are required.
        </p>
      )}
      {deliverState.error && <div className="alert bad" style={{ marginTop: 10 }}>{deliverState.error}</div>}
      {deliverState.ok && <div className="alert ok" style={{ marginTop: 10 }}>{deliverState.ok}</div>}

      {verifyState.error && <div className="alert bad" style={{ marginTop: 10 }}>{verifyState.error}</div>}
      {verifyState.ok && <div className="alert ok" style={{ marginTop: 10 }}>{verifyState.ok}</div>}
      {state.error && <div className="alert bad" style={{ marginTop: 10 }}>{state.error}</div>}
      {state.ok && <div className="alert ok" style={{ marginTop: 10 }}>{state.ok}</div>}
      {transportState.error && (
        <div className="alert bad" style={{ marginTop: 10 }}>{transportState.error}</div>
      )}
      {transportState.ok && (
        <div className="alert ok" style={{ marginTop: 10 }}>{transportState.ok}</div>
      )}

      <div style={{ marginTop: 10, border: "1px solid var(--line)", borderRadius: 6 }}>
        <DataTable
          label="certifications"
          columns={[
            { key: "credential", label: "Credential" },
            { key: "state", label: "State" },
            { key: "detail", label: "On file" },
            { key: "action", label: "", sortable: false },
          ]}
          rows={rows.map((r) => ({
            key: r.type_key,
            text: `${r.label} ${r.state} ${r.reference ?? ""}`,
            sort: {
              credential: r.label,
              state: r.state,
              detail: r.kind === "hours" ? Number(r.hours_this_year) : (r.expires_on ?? r.issued_on),
            },
            cells: {
              credential: (
                <>
                  {r.label}
                  {!r.required && <div className="lock">not required of them</div>}
                  {!readOnly && (
                    <RequiredChoice
                      staffId={staffId}
                      typeKey={r.type_key}
                      required={r.required}
                      decided={decidedBy.get(r.type_key)}
                    />
                  )}
                </>
              ),
              state: <span className={"chip " + (TONE[r.state] ?? "")}>{r.state}</span>,
              detail:
                r.kind === "hours" ? (
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
                ),
              action:
                r.state === "Awaiting check" && r.credential_id && !readOnly ? (
                  <span style={{ whiteSpace: "nowrap" }}>
                    {r.file_id && <OpenButton id={r.file_id} />}
                    <form action={verifyAction} style={{ display: "inline", marginLeft: 4 }}>
                      <input type="hidden" name="credential_id" value={r.credential_id} />
                      <button className="btn gold" type="submit" disabled={verifying} style={{ padding: "2px 10px" }}>
                        {verifying ? "…" : "Verify"}
                      </button>
                    </form>
                  </span>
                ) : r.kind !== "hours" && !readOnly ? (
                  <button
                    className="btn ghost"
                    type="button"
                    style={{ padding: "2px 10px", whiteSpace: "nowrap" }}
                    onClick={() => setAdding(adding === r.type_key ? null : r.type_key)}
                  >
                    {adding === r.type_key ? "Cancel" : r.state === "Missing" ? "Record" : "Renew"}
                  </button>
                ) : null,
            },
          }))}
          empty={`No certifications or clearances apply to ${staffName} yet.`}
        />
      </div>

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
            Verified by you, now. A renewal is added beside the old one.</p>
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

/**
 * Whether this person needs this credential (0288).
 *
 * Three states, not two: required, not required, or whatever the default says.
 * The third matters - an exception recorded for somebody who has since changed
 * jobs is an exception nobody meant to keep, and "follow the default" is how
 * it goes away rather than being flipped to the answer that happens to be
 * right today.
 *
 * The reason is asked for, not demanded. Somebody will type one when it is not
 * obvious and will not when it is, and a required field here would get "n/a".
 */
function RequiredChoice({
  staffId,
  typeKey,
  required,
  decided,
}: {
  staffId: string;
  typeKey: string;
  required: boolean;
  decided?: CredentialDecision;
}) {
  const [state, action, saving] = useActionState(setCredentialRequirement, initial);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <div className="lock">
        {decided ? (
          <>
            {decided.required ? "required" : "not required"} by decision
            {decided.reason ? ` — ${decided.reason}` : ""}{" "}
          </>
        ) : null}
        <button type="button" className="linkish" onClick={() => setOpen(true)}>
          {decided ? "Change" : "Say whether they need it"}
        </button>
        {state.error && <span style={{ color: "var(--bad)" }}> {state.error}</span>}
      </div>
    );
  }

  return (
    <form action={action} className="grid" style={{ gap: 4, marginTop: 4 }}>
      <input type="hidden" name="staff_id" value={staffId} />
      <input type="hidden" name="type_key" value={typeKey} />
      <label className="sr-only" htmlFor={`need-${staffId}-${typeKey}`}>
        Whether they need this credential
      </label>
      <select id={`need-${staffId}-${typeKey}`} name="choice" defaultValue={decided ? (decided.required ? "yes" : "no") : "default"}>
        <option value="default">Follow the practice default</option>
        <option value="yes">They need it</option>
        <option value="no">They do not need it</option>
      </select>
      <input name="reason" placeholder="Why, if it is not obvious" defaultValue={decided?.reason ?? ""} maxLength={200} />
      <div className="row2" style={{ gap: 6 }}>
        <button className="btn" type="submit" disabled={saving}>
          {saving ? "…" : "Record it"}
        </button>
        <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
          Leave it
        </button>
      </div>
      <span className="lock">{required ? "Required of them now" : "Not required of them now"}</span>
    </form>
  );
}
