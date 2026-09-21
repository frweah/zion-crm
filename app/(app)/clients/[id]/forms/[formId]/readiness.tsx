"use client";

import Link from "next/link";
import { useActionState } from "react";
import { refillForm, setFormAuthorization, type FormState } from "../actions";

const initial: FormState = { error: null, ok: null };

export type Blocker = { tone: "bad" | "warn"; text: string; href?: string; linkText?: string };

/**
 * What stands between this form and a counselor's inbox (punch list #3), said
 * before somebody signs rather than after the send is refused - and the two
 * things that can be fixed from here: which authorization it is for, and
 * filling it again from the record.
 */
export function FormReadiness({
  formId,
  clientId,
  blockers,
  draft,
  authChoices,
  suggested,
  canRefill,
}: {
  formId: string;
  clientId: string;
  blockers: Blocker[];
  draft: boolean;
  /** Offered only while the form has no authorization. */
  authChoices: { id: string; label: string }[];
  suggested: string | null;
  canRefill: boolean;
}) {
  const [attachState, attachAction, attaching] = useActionState(setFormAuthorization, initial);
  const [refillState, refillAction, refilling] = useActionState(refillForm, initial);

  if (blockers.length === 0 && !(draft && canRefill)) return null;

  return (
    <div className="card" style={{ marginTop: 14 }}>
      {blockers.length > 0 && (
        <>
          <h3 style={{ marginTop: 0 }}>Before this can go</h3>
          <ul style={{ margin: "0 0 10px", paddingLeft: 20 }}>
            {blockers.map((b) => (
              <li key={b.text} style={{ marginBottom: 4, color: b.tone === "bad" ? "var(--bad)" : undefined }}>
                {b.text}
                {b.href && (
                  <>
                    {" "}
                    <Link href={b.href}>{b.linkText ?? "Open"}</Link>
                  </>
                )}
              </li>
            ))}
          </ul>
        </>
      )}

      {draft && authChoices.length > 0 && (
        <form action={attachAction} className="row2" style={{ gap: 8, alignItems: "flex-end", marginBottom: 10 }}>
          <input type="hidden" name="form_id" value={formId} />
          <input type="hidden" name="client_id" value={clientId} />
          <label className="field" htmlFor="form-auth" style={{ flex: "1 1 260px" }}>
            Which authorization is this form for?
            <select id="form-auth" name="auth_id" defaultValue={suggested ?? ""} required>
              <option value="">— choose —</option>
              {authChoices.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.label}
                </option>
              ))}
            </select>
          </label>
          <button className="btn gold" type="submit" disabled={attaching}>
            {attaching ? "…" : "Attach"}
          </button>
          {attachState.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{attachState.error}</span>}
          {attachState.ok && <span className="lock">{attachState.ok}</span>}
        </form>
      )}

      {draft && canRefill && (
        <form action={refillAction} className="row2" style={{ gap: 8, alignItems: "center" }}>
          <input type="hidden" name="form_id" value={formId} />
          <input type="hidden" name="client_id" value={clientId} />
          <button className="btn ghost" type="submit" disabled={refilling}>
            {refilling ? "Filling…" : "Fill again from the record"}
          </button>
          <span className="lock">
            Replaces what the CRM fills in - hours, the daily log, the placement - with what is on the record now. What
            only you can know is kept.
          </span>
          {refillState.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{refillState.error}</span>}
          {refillState.ok && <span className="lock">{refillState.ok}</span>}
        </form>
      )}
    </div>
  );
}
