"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import { createForm, type FormState } from "./forms/actions";
import { FORM_TEMPLATES, templateById } from "@/lib/form-templates";
import { fmtStamp, today } from "@/lib/constants";

const initial: FormState = { error: null, ok: null };

export type FormRow = {
  id: string;
  template_id: string;
  status: string;
  month: string | null;
  auth_id: string | null;
  created_at: string;
  completed_at: string | null;
  completed_by_name: string;
  sent_to: string;
};

export type AuthChoice = { id: string; label: string; serviceType: string };

export function FormsTab({
  clientId,
  forms,
  auths,
  missingForBilling,
}: {
  clientId: string;
  forms: FormRow[];
  auths: AuthChoice[];
  missingForBilling: { authLabel: string; usor: string[] }[];
}) {
  const [state, action, pending] = useActionState(createForm, initial);
  const [templateId, setTemplateId] = useState("");

  const template = templateId ? templateById(templateId) : undefined;

  return (
    <>
      {missingForBilling.length > 0 && (
        <div className="alert">
          <b>Outstanding before billing:</b>
          <ul style={{ margin: "6px 0 0", paddingLeft: 20 }}>
            {missingForBilling.map((m) => (
              <li key={m.authLabel}>
                {m.authLabel} — {m.usor.join(" + ")}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="card" style={{ marginBottom: 14 }}>
        <h3>Start a form</h3>
        {state.error && <div className="alert bad">{state.error}</div>}

        <form action={action}>
          <input type="hidden" name="client_id" value={clientId} />
          <div className="row2">
            <label className="field" style={{ flex: 2 }}>
              Form
              <select
                name="template_id"
                required
                value={templateId}
                onChange={(e) => setTemplateId(e.target.value)}
              >
                <option value="">— choose —</option>
                {FORM_TEMPLATES.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.usor} — {t.name}
                  </option>
                ))}
              </select>
            </label>

            <label className="field">
              Authorization
              <select name="auth_id" defaultValue="">
                <option value="">— none —</option>
                {auths.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.label}
                  </option>
                ))}
              </select>
            </label>

            {template?.monthly && (
              <label className="field" style={{ maxWidth: 170 }}>
                Reporting month
                <input name="month" type="month" defaultValue={today().slice(0, 7)} />
              </label>
            )}

            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Starting…" : "Start form"}
            </button>
          </div>
        </form>

        {template && (
          <p className="lock" style={{ margin: "10px 0 0" }}>
            {template.due}
            {template.sensitive && " This form holds restricted content."}
          </p>
        )}
      </div>

      {forms.length === 0 ? (
        <div className="empty">No forms for this client yet.</div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <table className="t">
            <thead>
              <tr>
                <th>Form</th>
                <th>Month</th>
                <th>Status</th>
                <th>Signed</th>
              </tr>
            </thead>
            <tbody>
              {forms.map((f) => {
                const t = templateById(f.template_id);
                return (
                  <tr key={f.id} className="row">
                    <td>
                      <Link
                        href={`/clients/${clientId}/forms/${f.id}`}
                        style={{ color: "inherit", fontWeight: 600 }}
                      >
                        {t?.usor ?? f.template_id}
                      </Link>
                      <div style={{ fontSize: 12, color: "var(--muted)" }}>{t?.name}</div>
                    </td>
                    <td>{f.month ?? "—"}</td>
                    <td>
                      <span
                        className={
                          "chip " +
                          (f.status === "Sent" ? "ok" : f.status === "Completed" ? "gold" : "")
                        }
                      >
                        {f.status}
                      </span>
                    </td>
                    <td style={{ fontSize: 12, color: "var(--muted)" }}>
                      {f.status === "Draft"
                        ? `started ${fmtStamp(f.created_at)}`
                        : f.status === "Sent"
                          ? `sent to ${f.sent_to}`
                          : `${f.completed_by_name} · ${fmtStamp(f.completed_at)}`}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
