"use client";

import { useActionState, useState } from "react";
import { fmtStamp } from "@/lib/constants";
import {
  givePortalAccess,
  sendInvitation,
  turnOffPortalAccess,
  signOutOfPortal,
  type PortalAdminState,
} from "./portal-actions";

export type PortalAccountRow = {
  id: string;
  kind: string;
  name: string;
  relationship: string;
  phone: string | null;
  email: string | null;
  invited_at: string;
  invited_by_name: string;
  first_signed_in_at: string | null;
  last_signed_in_at: string | null;
  disabled_at: string | null;
  disabled_reason: string;
};

export type PortalConsentRow = {
  account_id: string;
  kind: string;
  given: boolean;
  at: string;
  terms_version: string;
};

export type PortalActivityRow = {
  id: string;
  at: string;
  action: string;
  detail: string;
  actor_name: string;
};

export type GuardianshipDoc = { id: string; filename: string; created_at: string };

const initial: PortalAdminState = { error: null, ok: null };

/**
 * The client portal, from the client's record: who can sign in for this
 * client, whether they have agreed to the terms, and the four things staff do
 * - give access, tell them about it, turn it off, sign everybody out.
 */
export function PortalPanel({
  clientId,
  clientName,
  clientPhone,
  clientEmail,
  accounts,
  consents,
  activity,
  guardianshipDocs,
  termsVersion,
  canManage,
  canText,
  portalUrl,
}: {
  clientId: string;
  clientName: string;
  clientPhone: string;
  clientEmail: string;
  accounts: PortalAccountRow[];
  consents: PortalConsentRow[];
  activity: PortalActivityRow[];
  guardianshipDocs: GuardianshipDoc[];
  termsVersion: string | null;
  canManage: boolean;
  canText: boolean;
  portalUrl: string;
}) {
  const [giveState, giveAction, giving] = useActionState(givePortalAccess, initial);
  const [sendState, sendAction, sending] = useActionState(sendInvitation, initial);
  const [offState, offAction, turningOff] = useActionState(turnOffPortalAccess, initial);
  const [outState, outAction, signingOut] = useActionState(signOutOfPortal, initial);

  const live = accounts.filter((a) => !a.disabled_at);
  const clientHasAccess = live.some((a) => a.kind === "Client");
  const [adding, setAdding] = useState(false);
  const [kind, setKind] = useState<"Client" | "Guardian">(clientHasAccess ? "Guardian" : "Client");
  const [closing, setClosing] = useState<string | null>(null);

  const first = clientName.trim().split(/\s+/)[0] || "this client";
  const error = giveState.error ?? sendState.error ?? offState.error ?? outState.error;
  const ok = giveState.ok ?? sendState.ok ?? offState.ok ?? outState.ok;

  // Newest first, so the first match is where consent stands now.
  const consentLine = (accountId: string): string => {
    const latest = consents.find((c) => c.account_id === accountId && c.kind === "Electronic communication");
    if (!latest) return "has not agreed to the terms yet";
    if (!latest.given) return `withdrew consent ${fmtStamp(latest.at)}`;
    if (termsVersion && latest.terms_version !== termsVersion) {
      return `agreed to terms ${latest.terms_version}; will be asked again for ${termsVersion}`;
    }
    return `agreed to terms ${latest.terms_version} ${fmtStamp(latest.at)}`;
  };

  // What giving access will do, in the words of the rule: email if there is an
  // address, a text only where texting consent already exists, otherwise the
  // staff member tells them.
  const howTheyLearn = (): string => {
    if (kind === "Guardian") return "An email invitation goes out if you give an email address; otherwise tell them yourself.";
    if (clientEmail) return `An invitation will go by email to ${clientEmail}.`;
    if (canText && clientPhone) return `An invitation will go by text to ${clientPhone}.`;
    return "Nothing will be sent, because there is no email address and no texting consent. Tell them in person.";
  };

  return (
    <div className="card" style={{ marginTop: 14 }} id="portal">
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <div>
          <h3 style={{ margin: 0 }}>Client portal</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            {live.length === 0
              ? `Nobody can sign in to the portal for ${first}.`
              : `${live.length} ${live.length === 1 ? "person" : "people"} can sign in for ${first}.`}
          </p>
        </div>
        {canManage && (
          <button className="btn" type="button" onClick={() => setAdding(!adding)}>
            {adding ? "Cancel" : "Give portal access"}
          </button>
        )}
      </div>

      {error && <div className="alert bad" style={{ marginTop: 10 }}>{error}</div>}
      {ok && <div className="alert ok" style={{ marginTop: 10 }}>{ok}</div>}

      {adding && canManage && (
        <form action={giveAction} style={{ marginTop: 12 }}>
          <input type="hidden" name="client_id" value={clientId} />
          <fieldset style={{ border: 0, padding: 0, margin: "0 0 8px" }}>
            <legend className="label">Who it is for</legend>
            <label className="field">
              <input
                type="radio"
                name="kind"
                value="Client"
                checked={kind === "Client"}
                disabled={clientHasAccess}
                onChange={() => setKind("Client")}
              />{" "}
              {first} {clientHasAccess ? "(already has access)" : ""}
            </label>
            <label className="field">
              <input type="radio" name="kind" value="Guardian" checked={kind === "Guardian"} onChange={() => setKind("Guardian")} />{" "}
              A parent or legal guardian
            </label>
          </fieldset>

          {kind === "Guardian" && (
            <>
              <div className="row2">
                <label className="field">
                  Guardian&apos;s name
                  <input name="name" required />
                </label>
                <label className="field">
                  Relationship to {first}
                  <input name="relationship" required placeholder="Mother, legal guardian…" />
                </label>
              </div>
              {guardianshipDocs.length === 0 ? (
                <div className="alert" style={{ marginTop: 10 }}>
                  A guardian can be given access only with a guardianship document on {first}&apos;s file.
                  Upload it on Documents with the category Guardianship document first.
                </div>
              ) : (
                <label className="field" style={{ marginTop: 10 }}>
                  Guardianship document
                  <select name="attachment_id" required>
                    {guardianshipDocs.map((d) => (
                      <option key={d.id} value={d.id}>
                        {d.filename} · added {d.created_at.slice(0, 10)}
                      </option>
                    ))}
                  </select>
                </label>
              )}
            </>
          )}

          <div className="row2" style={{ marginTop: 10 }}>
            <label className="field">
              Mobile number for sign-in codes
              <input
                name="phone"
                placeholder={kind === "Client" ? clientPhone || "No phone on the record" : "801-555-0123"}
              />
              <small>
                {kind === "Client" ? "Leave blank to use the number on the record." : "The guardian's own number."}
              </small>
            </label>
            <label className="field">
              Email for sign-in codes
              <input
                name="email"
                type="email"
                placeholder={kind === "Client" ? clientEmail || "No email on the record" : ""}
              />
              <small>
                {kind === "Client" ? "Leave blank to use the email on the record." : "Optional when there is a mobile number."}
              </small>
            </label>
          </div>

          <button
            className="btn gold"
            type="submit"
            disabled={giving || (kind === "Guardian" && guardianshipDocs.length === 0)}
          >
            {giving ? "Saving…" : "Give access"}
          </button>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            {howTheyLearn()} A text is only ever sent where texting consent already exists for that number.
            They sign in at {portalUrl} with the number or email on the account, and a code arrives each
            time. The terms come before anything else.
          </p>
        </form>
      )}

      {accounts.length > 0 && (
        <div className="list" style={{ marginTop: 12 }}>
          {accounts.map((a) => (
            <div className="list-item" key={a.id}>
              <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
                <div>
                  <b>{a.name}</b>{" "}
                  <span className="chip">{a.kind === "Guardian" ? `Guardian · ${a.relationship}` : "Client"}</span>{" "}
                  {a.disabled_at ? (
                    <span className="chip bad">Turned off</span>
                  ) : a.last_signed_in_at ? (
                    <span className="chip ok">Signed in before</span>
                  ) : (
                    <span className="chip warn">Not signed in yet</span>
                  )}
                  <div className="lock">Codes go to {[a.phone, a.email].filter(Boolean).join(" or ")}</div>
                  <div className="lock">
                    {a.disabled_at
                      ? `Turned off ${fmtStamp(a.disabled_at)}: ${a.disabled_reason}`
                      : a.last_signed_in_at
                        ? `Last signed in ${fmtStamp(a.last_signed_in_at)} · ${consentLine(a.id)}`
                        : `Access given ${fmtStamp(a.invited_at)}${a.invited_by_name ? ` by ${a.invited_by_name}` : ""}`}
                  </div>
                </div>
                {canManage && !a.disabled_at && closing !== a.id && (
                  <div className="row2" style={{ gap: 6 }}>
                    {!a.first_signed_in_at && (a.email || a.phone) && (
                      <form action={sendAction}>
                        <input type="hidden" name="client_id" value={clientId} />
                        <input type="hidden" name="account_id" value={a.id} />
                        <button className="btn ghost" type="submit" disabled={sending}>
                          {sending ? "…" : "Send the invitation"}
                        </button>
                      </form>
                    )}
                    <button className="btn ghost" type="button" onClick={() => setClosing(a.id)}>
                      Turn off access
                    </button>
                  </div>
                )}
              </div>
              {closing === a.id && (
                <form action={offAction} className="row2" style={{ marginTop: 8 }}>
                  <input type="hidden" name="client_id" value={clientId} />
                  <input type="hidden" name="account_id" value={a.id} />
                  <label className="field" style={{ flex: 3 }}>
                    Why access is being turned off
                    <input name="reason" required placeholder="Case closed, guardian asked, lost phone…" />
                  </label>
                  <button className="btn danger" type="submit" disabled={turningOff}>
                    {turningOff ? "…" : "Turn off"}
                  </button>
                  <button className="btn ghost" type="button" onClick={() => setClosing(null)}>
                    Cancel
                  </button>
                </form>
              )}
            </div>
          ))}
        </div>
      )}

      {canManage && live.length > 0 && (
        <form action={outAction} style={{ marginTop: 10 }}>
          <input type="hidden" name="client_id" value={clientId} />
          <button className="btn ghost" type="submit" disabled={signingOut}>
            {signingOut ? "…" : "Sign everyone out of the portal"}
          </button>
        </form>
      )}

      {activity.length > 0 && (
        <details style={{ marginTop: 10 }}>
          <summary className="lock">Portal activity</summary>
          <div className="list">
            {activity.map((e) => (
              <div className="list-item" key={e.id}>
                <span className="lock">{fmtStamp(e.at)}</span> {e.action}
                {e.detail ? ` · ${e.detail}` : ""}
                {e.actor_name ? ` · ${e.actor_name}` : ""}
              </div>
            ))}
          </div>
        </details>
      )}
    </div>
  );
}
