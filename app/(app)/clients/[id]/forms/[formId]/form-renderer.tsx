"use client";

import { useState, useActionState } from "react";
import { saveForm, completeForm, sendForm, type FormState } from "../actions";
import {
  isHeading,
  validateForm,
  type Field,
  type FormTemplate,
  type TableColumn,
} from "@/lib/form-templates";
import { COACHING_CODES } from "@/lib/constants";
import type { Recipients } from "@/lib/billing-offices";

const initial: FormState = { error: null, ok: null };

type Data = Record<string, unknown>;
type YesNo = { v?: string; x?: string };
type Row = Record<string, string>;

function Message({ state }: { state: FormState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

/** One field, rendered by its type. */
function FieldInput({
  field,
  value,
  onChange,
  disabled,
}: {
  field: Extract<Field, { k: string }>;
  value: unknown;
  onChange: (v: unknown) => void;
  disabled: boolean;
}) {
  const id = `f_${field.k}`;

  switch (field.t) {
    case "textarea":
      return (
        <label className="field" htmlFor={id}>
          {field.l}
          <textarea
            id={id}
            rows={3}
            value={(value as string) ?? ""}
            onChange={(e) => onChange(e.target.value)}
            disabled={disabled}
          />
        </label>
      );

    case "select":
      return (
        <label className="field" htmlFor={id}>
          {field.l}
          <select
            id={id}
            value={(value as string) ?? ""}
            onChange={(e) => onChange(e.target.value)}
            disabled={disabled}
          >
            <option value="">—</option>
            {(field.o ?? []).map((o) => (
              <option key={o}>{o}</option>
            ))}
          </select>
        </label>
      );

    case "check":
      return (
        <label style={{ fontSize: "var(--text-md)", display: "block", margin: "10px 0" }}>
          <input
            type="checkbox"
            style={{ width: "auto", marginRight: 8 }}
            checked={Boolean(value)}
            onChange={(e) => onChange(e.target.checked)}
            disabled={disabled}
          />
          {field.l}
        </label>
      );

    case "checks": {
      const selected = (value as string[]) ?? [];
      return (
        <div className="field">
          {field.l}
          <div style={{ marginTop: 6, display: "flex", flexDirection: "column", gap: 4 }}>
            {(field.o ?? []).map((o) => (
              <label key={o} style={{ fontSize: "var(--text-md)", color: "var(--ink)" }}>
                <input
                  type="checkbox"
                  style={{ width: "auto", marginRight: 8 }}
                  checked={selected.includes(o)}
                  onChange={(e) =>
                    onChange(
                      e.target.checked ? [...selected, o] : selected.filter((x) => x !== o),
                    )
                  }
                  disabled={disabled}
                />
                {o}
              </label>
            ))}
          </div>
        </div>
      );
    }

    case "rating":
      return (
        <label className="field" htmlFor={id} style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <span style={{ flex: 1 }}>{field.l}</span>
          <select
            id={id}
            value={(value as string) ?? ""}
            onChange={(e) => onChange(e.target.value)}
            disabled={disabled}
            style={{ maxWidth: 90 }}
          >
            <option value="">—</option>
            {Array.from({ length: 10 }, (_, i) => String(i + 1)).map((n) => (
              <option key={n}>{n}</option>
            ))}
          </select>
        </label>
      );

    case "yesno": {
      const yn = (value as YesNo) ?? {};
      return (
        <div className="field">
          <div style={{ display: "flex", gap: 10, alignItems: "flex-start" }}>
            <span style={{ flex: 1 }}>{field.l}</span>
            <select
              value={yn.v ?? ""}
              onChange={(e) => onChange({ ...yn, v: e.target.value })}
              disabled={disabled}
              style={{ maxWidth: 100 }}
            >
              <option value="">—</option>
              <option>Yes</option>
              <option>No</option>
            </select>
          </div>
          {field.explain && yn.v === "No" && (
            <textarea
              rows={2}
              placeholder="Explanation"
              value={yn.x ?? ""}
              onChange={(e) => onChange({ ...yn, x: e.target.value })}
              disabled={disabled}
              style={{ marginTop: 6 }}
            />
          )}
        </div>
      );
    }

    case "table": {
      const cols = (field.cols ?? []) as TableColumn[];
      const rows = ((value as Row[]) ?? []).map((r) => ({ ...r }));

      const setCell = (i: number, key: string, v: string) => {
        const next = rows.map((r, ri) => (ri === i ? { ...r, [key]: v } : r));
        onChange(next);
      };

      return (
        <div className="field">
          {field.l}
          <div style={{ overflowX: "auto", marginTop: 6 }}>
            <table className="t" data-layout="the form's own grid of inputs">
              <thead>
                <tr>
                  {cols.map((c) => (
                    <th key={c[0]}>{c[1]}</th>
                  ))}
                  {!disabled && <th style={{ width: 32 }} />}
                </tr>
              </thead>
              <tbody>
                {rows.length === 0 && (
                  <tr>
                    <td colSpan={cols.length + 1} className="empty">
                      No rows.
                    </td>
                  </tr>
                )}
                {rows.map((row, i) => (
                  <tr key={i}>
                    {cols.map((c) => (
                      <td key={c[0]}>
                        {c[2] === "code" ? (
                          <select
                            value={row[c[0]] ?? ""}
                            onChange={(e) => setCell(i, c[0], e.target.value)}
                            disabled={disabled}
                          >
                            <option value="">—</option>
                            {COACHING_CODES.map((code) => (
                              <option key={code} value={code.split(".")[0]}>
                                {code}
                              </option>
                            ))}
                          </select>
                        ) : (
                          <input
                            type={c[2] === "date" ? "date" : c[2] === "number" ? "number" : "text"}
                            value={row[c[0]] ?? ""}
                            onChange={(e) => setCell(i, c[0], e.target.value)}
                            disabled={disabled}
                          />
                        )}
                      </td>
                    ))}
                    {!disabled && (
                      <td>
                        <button
                          type="button"
                          className="btn ghost"
                          style={{ padding: "2px 8px" }}
                          onClick={() => onChange(rows.filter((_, ri) => ri !== i))}
                          aria-label="Remove row"
                        >
                          ×
                        </button>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {!disabled && (
            <button
              type="button"
              className="btn ghost"
              style={{ marginTop: 8 }}
              onClick={() =>
                onChange([...rows, Object.fromEntries(cols.map((c) => [c[0], ""])) as Row])
              }
            >
              Add row
            </button>
          )}
        </div>
      );
    }

    default:
      return (
        <label className="field" htmlFor={id}>
          {field.l}
          <input
            id={id}
            type={field.t === "date" ? "date" : field.t === "number" ? "number" : field.t === "month" ? "month" : "text"}
            value={(value as string) ?? ""}
            onChange={(e) => onChange(e.target.value)}
            disabled={disabled}
          />
        </label>
      );
  }
}

export function FormRenderer({
  template,
  formId,
  clientId,
  initialData,
  status,
  locked,
  signedBy,
  signedAt,
  sentTo,
  recipients,
  counselorName,
  preview,
}: {
  template: FormTemplate;
  formId: string;
  clientId: string;
  initialData: Data;
  status: string;
  locked: boolean;
  signedBy: string;
  signedAt: string | null;
  sentTo: string;
  recipients: Recipients;
  counselorName: string;
  preview: string;
}) {
  const [data, setData] = useState<Data>(initialData);
  const [showPreview, setShowPreview] = useState(false);

  const [saveState, saveAction, saving] = useActionState(saveForm, initial);
  const [completeState, completeAction, completing] = useActionState(completeForm, initial);
  const [sendState, sendAction, sending] = useActionState(sendForm, initial);

  const set = (k: string, v: unknown) => setData((d) => ({ ...d, [k]: v }));
  const payload = JSON.stringify(data);
  const problem = validateForm(template.id, data);

  return (
    <>
      <Message state={saveState} />
      <Message state={completeState} />
      <Message state={sendState} />

      {locked && (
        <div className="alert ok">
          Signed by {signedBy} on {signedAt?.slice(0, 10)}. This form is locked — start a new one
          if something needs changing.
          {sentTo && ` Sent to ${sentTo}.`}
        </div>
      )}

      {problem && !locked && <div className="alert bad">{problem}</div>}

      <div className="card">
        {template.fields.map((f, i) =>
          isHeading(f) ? (
            <h3
              key={`h${i}`}
              style={{
                marginTop: i === 0 ? 0 : 22,
                paddingTop: 12,
                borderTop: i === 0 ? "none" : "1px solid var(--line)",
              }}
            >
              {f.heading}
            </h3>
          ) : (
            <FieldInput
              key={f.k}
              field={f}
              value={data[f.k]}
              onChange={(v) => set(f.k, v)}
              disabled={locked}
            />
          ),
        )}
      </div>

      <div className="card" style={{ marginTop: 14 }}>
        <div className="row2">
          {!locked && (
            <>
              <form action={saveAction}>
                <input type="hidden" name="form_id" value={formId} />
                <input type="hidden" name="client_id" value={clientId} />
                <input type="hidden" name="payload" value={payload} />
                <button className="btn ghost" type="submit" disabled={saving}>
                  {saving ? "Saving…" : "Save draft"}
                </button>
              </form>

              <form action={completeAction}>
                <input type="hidden" name="form_id" value={formId} />
                <input type="hidden" name="client_id" value={clientId} />
                <input type="hidden" name="payload" value={payload} />
                <button
                  className="btn gold"
                  type="submit"
                  disabled={completing || Boolean(problem)}
                >
                  {completing ? "Signing…" : "Sign and lock"}
                </button>
              </form>
            </>
          )}

          {status === "Completed" && (
            <form action={sendAction} style={{ flexBasis: "100%" }}>
              <input type="hidden" name="form_id" value={formId} />
              <input type="hidden" name="client_id" value={clientId} />
              <div className="row2">
                <label className="field" htmlFor="form-send-to">
                  To
                  <input id="form-send-to" name="to" type="email" defaultValue={recipients.to} required />
                  <small>{recipients.toLabel || "Nobody yet"}</small>
                </label>
                <label className="field" htmlFor="form-send-cc">
                  Copy
                  <input id="form-send-cc" name="cc" defaultValue={recipients.cc} />
                  <small>{recipients.ccLabel || "Nobody"}</small>
                </label>
                <button className="btn" type="submit" disabled={sending}>
                  {sending ? "Sending…" : "Email the form"}
                </button>
              </div>
              {recipients.note && (
                <p className="lock" style={{ margin: "6px 0 0" }}>
                  {recipients.note}
                </p>
              )}
            </form>
          )}

          <button className="btn ghost" type="button" onClick={() => setShowPreview(!showPreview)}>
            {showPreview ? "Hide" : "Preview"} the email
          </button>
        </div>

        {!locked && (
          <p className="lock" style={{ margin: "10px 0 0" }}>
            Signing records your name and the time, and locks the content. Nothing is sent until
            you choose to email it - to the client's billing office, copying the counselor ({counselorName || "none on file"}).
          </p>
        )}

      </div>

      {showPreview && (
        <div className="card" style={{ marginTop: 14 }}>
          <h3>What the email says</h3>
          <pre
            style={{
              margin: 0,
              whiteSpace: "pre-wrap",
              fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
              fontSize: "var(--text-md)",
              lineHeight: 1.55,
            }}
          >
            {preview}
          </pre>
          <p className="lock" style={{ margin: "10px 0 0" }}>
            Built from what was saved. Save the draft to refresh this after an edit.
          </p>
        </div>
      )}
    </>
  );
}
