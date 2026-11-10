"use client";

import { useActionState, useState } from "react";
import { assignDocument, clientFromDocument } from "./whose-actions";
import type { InboxState } from "./actions";

const initial: InboxState = { error: null, ok: null };

export type Counselor = { id: string; name: string };

/** What the parse made of the PDF, and the line it read it off. */
type Field = { value?: string | null; source?: string | null };

function field(parsed: Record<string, unknown>, key: string): Field {
  const fields = (parsed.fields ?? {}) as Record<string, Field | undefined>;
  return fields[key] ?? {};
}

function Said({ state }: { state: InboxState }) {
  if (state.error) return <p className="alert bad">{state.error}</p>;
  if (state.ok) return <p className="alert ok">{state.ok}</p>;
  return null;
}

/**
 * Whose a waiting document is (C3, 9 November 2026).
 *
 * Two answers, and the second is the one that was missing: a document about
 * somebody the practice has never had a record for. The form is filled in
 * from the PDF and every field can be changed, because the parse is often
 * wrong in a way that matters — it reads the name as running into the words
 * the form prints after it, so its suggestion can be a first name with
 * "Client ID" on the end.
 *
 * So the line the parse read is shown underneath each suggestion. A person
 * reading "Client Name: Surname, Firstname Client ID: 89914" can see what the
 * name is; the parse cannot.
 */
export function WhoseDocument({
  docId,
  parsed,
  clients,
  counselors,
  offices,
}: {
  docId: string;
  parsed: Record<string, unknown>;
  clients: { id: string; name: string }[];
  counselors: Counselor[];
  offices: string[];
}) {
  const [assignState, assign, assigning] = useActionState(assignDocument, initial);
  const [makeState, make, making] = useActionState(clientFromDocument, initial);
  const [adding, setAdding] = useState(false);

  const name = field(parsed, "clientName");
  const counselor = field(parsed, "counselorName");
  const office = field(parsed, "office");
  const agency = field(parsed, "agencyId");

  // The counselor the PDF names, where the practice has them on file.
  const match = counselors.find(
    (c) => c.name.trim().toLowerCase() === (counselor.value ?? "").trim().toLowerCase(),
  );

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <Said state={assignState} />
      <Said state={makeState} />

      <form action={assign} className="row2" style={{ gap: 6, alignItems: "center" }}>
        <input type="hidden" name="document_id" value={docId} />
        <label className="field" style={{ maxWidth: 280 }}>
          <span>Assign to client</span>
          <select name="client_id" defaultValue="">
            <option value="">Choose the client…</option>
            {clients.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <button className="btn" disabled={assigning}>
          {assigning ? "…" : "That is them"}
        </button>
        {!adding && (
          <button type="button" className="btn ghost" onClick={() => setAdding(true)}>
            New client from this document
          </button>
        )}
      </form>

      {adding && (
        <form action={make} style={{ marginTop: 10 }}>
          <input type="hidden" name="document_id" value={docId} />
          <div className="row2">
            <label className="field" style={{ flex: 2 }}>
              <span>Name</span>
              <input name="name" defaultValue={name.value ?? ""} required />
            </label>
            <label className="field">
              <span>Client ID</span>
              <input name="agency_id" defaultValue={agency.value ?? ""} />
            </label>
          </div>
          {name.source && (
            <p className="lock" style={{ marginTop: -4 }}>
              The form says: {name.source}
            </p>
          )}

          <div className="row2">
            <label className="field">
              <span>Counselor</span>
              <select name="counselor_id" defaultValue={match?.id ?? ""}>
                <option value="">Not on file yet</option>
                {counselors.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="field">
              <span>Office</span>
              <select name="office" defaultValue={office.value ?? ""}>
                <option value="">Not on the document</option>
                {offices.map((o) => (
                  <option key={o} value={o}>
                    {o}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {counselor.value && !match && (
            <p className="lock">
              The form names {counselor.value}, who is not in the directory. Add them on
              Counselors, or leave this blank.
            </p>
          )}

          <label className="field">
            <span>Why there is no number</span>
            <input
              name="no_phone_reason"
              defaultValue="Added from a document; no number on it"
            />
          </label>

          <button className="btn" disabled={making}>
            {making ? "…" : "Add them"}
          </button>
          <button
            type="button"
            className="btn ghost"
            style={{ marginLeft: 6 }}
            onClick={() => setAdding(false)}
          >
            Leave it
          </button>
        </form>
      )}
    </div>
  );
}
