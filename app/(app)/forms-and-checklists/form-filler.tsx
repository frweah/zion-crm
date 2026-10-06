"use client";

import { useActionState, useRef, useState } from "react";
import { fillForm, type FillState, type FormField } from "./actions";
import { readyDocument, tooBig } from "../paperwork/ready-for-upload";

const initial: FillState = { error: null, ok: null };

export type PracticeForm = {
  key: string;
  name: string;
  purpose: string | null;
  fields: FormField[];
  about_a_client: boolean;
};

/**
 * One of the practice's forms, filled in (Design language, §3).
 *
 * Built for a phone first: one field per line, real keyboards for numbers and
 * dates, and a photograph taken with the camera rather than found in a folder.
 * The photograph is shrunk here before it is sent, by the same helper the
 * paperwork uploads use - a page photographed on a phone is four megabytes of
 * camera and a few hundred kilobytes of document.
 */
export function FormFiller({ form, clients }: { form: PracticeForm; clients: { id: string; name: string }[] }) {
  const [state, action, pending] = useActionState(fillForm, initial);
  const [open, setOpen] = useState(false);
  const [trouble, setTrouble] = useState<string | null>(null);
  const [preparing, setPreparing] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);

  async function submit(data: FormData) {
    setTrouble(null);
    const photo = data.get("photo");
    if (photo instanceof File && photo.size > 0) {
      setPreparing(true);
      let ready: File;
      try {
        ready = await readyDocument(photo);
      } finally {
        setPreparing(false);
      }
      const complaint = tooBig(ready);
      if (complaint) {
        setTrouble(complaint);
        return;
      }
      data.set("photo", ready);
    }
    await action(data);
    formRef.current?.reset();
    setOpen(false);
  }

  if (!open) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>{form.name}</h3>
        {form.purpose && <p className="lock" style={{ marginTop: 0 }}>{form.purpose}</p>}
        {state.ok && <div className="alert ok">{state.ok}</div>}
        <button className="btn gold" type="button" onClick={() => setOpen(true)}>
          Fill one in
        </button>
      </div>
    );
  }

  return (
    <form action={submit} ref={formRef} className="card">
      <h3 style={{ marginTop: 0 }}>{form.name}</h3>
      {form.purpose && <p className="lock" style={{ marginTop: 0 }}>{form.purpose}</p>}
      {state.error && <div className="alert bad">{state.error}</div>}
      {trouble && <div className="alert bad">{trouble}</div>}

      <input type="hidden" name="form_key" value={form.key} />

      {form.about_a_client && (
        <label className="field">
          Which client
          <select name="client_id" required>
            <option value="">—</option>
            {clients.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
      )}

      {form.fields.map((f) => {
        if (f.type === "signature") {
          return (
            <p key={f.key} className="lock">
              Signed by you when you save it, with your signature from Paperwork.
            </p>
          );
        }
        if (f.type === "photo") {
          return (
            <label key={f.key} className="field">
              {f.label}
              <input type="file" name="photo" accept="image/*" capture="environment" />
            </label>
          );
        }
        return (
          <label key={f.key} className="field">
            {f.label}
            {f.type === "long" ? (
              <textarea name={f.key} rows={3} required={f.required} />
            ) : f.type === "yes_no" ? (
              <select name={f.key} required={f.required}>
                <option value="">—</option>
                <option value="Yes">Yes</option>
                <option value="No">No</option>
              </select>
            ) : (
              <input
                name={f.key}
                type={f.type === "number" ? "number" : f.type === "date" ? "date" : "text"}
                inputMode={f.type === "number" ? "decimal" : undefined}
                step={f.type === "number" ? "0.01" : undefined}
                required={f.required}
              />
            )}
          </label>
        );
      })}

      <div className="row2" style={{ gap: 8, marginTop: 12 }}>
        <button className="btn gold" type="submit" disabled={pending || preparing}>
          {preparing ? "Preparing…" : pending ? "Saving…" : "Save it"}
        </button>
        <button className="row-link" type="button" onClick={() => setOpen(false)}>
          Not now
        </button>
      </div>
    </form>
  );
}
