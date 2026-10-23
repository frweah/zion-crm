"use client";

import { useActionState } from "react";
import {
  saveMailNoticeRecipient,
  saveMailSignature,
  saveMailTemplate,
  type TemplateState,
} from "./actions";

const initial: TemplateState = { error: null, ok: null };

function Message({ state }: { state: TemplateState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

/** One letter, its subject and its words. */
export function TemplateForm({
  template,
  fields,
}: {
  template: { key: string; label: string; subject: string; body: string; active: boolean };
  fields: string[];
}) {
  const [state, action, pending] = useActionState(saveMailTemplate, initial);
  return (
    <form action={action} className="card" style={{ marginBottom: 16 }}>
      <Message state={state} />
      <input type="hidden" name="key" value={template.key} />
      <label className="field">
        Name
        <input id={`label-${template.key}`} name="label" defaultValue={template.label} required />
      </label>
      <label className="field">
        Subject
        <input id={`subject-${template.key}`} name="subject" defaultValue={template.subject} required />
      </label>
      <label className="field">
        Message
        <textarea id={`body-${template.key}`} name="body" rows={12} defaultValue={template.body} required />
      </label>
      <p className="lock" style={{ margin: "0 0 10px" }}>
        Fields: {fields.join(" ")}
      </p>
      <div className="row2" style={{ gap: 10, alignItems: "center" }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save"}
        </button>
        <label className="row2" style={{ gap: 6, alignItems: "baseline" }}>
          <input type="checkbox" name="active" defaultChecked={template.active} />
          <span>Offered in Compose</span>
        </label>
      </div>
    </form>
  );
}

/** The lines under every message the CRM sends. */
export function SignatureForm({ signature }: { signature: string }) {
  const [state, action, pending] = useActionState(saveMailSignature, initial);
  return (
    <form action={action} className="card" style={{ marginBottom: 16 }}>
      <Message state={state} />
      <label className="field">
        Signature
        <textarea id="signature" name="signature" rows={4} defaultValue={signature} />
      </label>
      <button className="btn gold" type="submit" disabled={pending}>
        {pending ? "Saving…" : "Save"}
      </button>
    </form>
  );
}

/** Who hears about every reply that files itself. */
export function NoticeRecipientForm({
  staff,
  current,
}: {
  staff: { id: string; name: string; role: string }[];
  current: string | null;
}) {
  const [state, action, pending] = useActionState(saveMailNoticeRecipient, initial);
  return (
    <form action={action} className="card" style={{ marginBottom: 16 }}>
      <Message state={state} />
      <label className="field">
        Told about every reply
        <select id="notice-staff" name="staff_id" defaultValue={current ?? ""}>
          <option value="">Nobody</option>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name} — {s.role}
            </option>
          ))}
        </select>
      </label>
      <button className="btn gold" type="submit" disabled={pending}>
        {pending ? "Saving…" : "Save"}
      </button>
    </form>
  );
}
