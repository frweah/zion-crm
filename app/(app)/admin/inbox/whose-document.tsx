"use client";

import { useActionState, useMemo, useState } from "react";
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
 * A name as words, lowercased and sorted, so that the order it is written in
 * does not matter.
 *
 * USOR prints "Surname, Firstname" and the practice holds "Firstname Surname".
 * Comparing the two as strings never matches; comparing them as sets of words
 * always does.
 */
const words = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z ]+/g, " ")
    .split(/\s+/)
    .filter(Boolean);

/**
 * The client the PDF is about, where the practice has them on file.
 *
 * Every word of the client's name has to appear in what was read, rather than
 * the two matching outright, because the parse reads the name as running into
 * the words the form prints after it: "Surname, Firstname Client ID 89914" is
 * a normal reading. Two words at least, so a one-word name cannot match
 * everybody.
 *
 * It is a suggestion and it is pre-chosen rather than applied: nothing is
 * assigned until somebody presses the button, and the line the parse read is
 * printed underneath so they can see what it saw.
 */
export function bestMatch(read: string, clients: { id: string; name: string }[]) {
  const got = words(read);
  if (got.length === 0) return undefined;
  return clients.find((c) => {
    const mine = words(c.name);
    return mine.length > 1 && mine.every((w) => got.includes(w));
  });
}

/**
 * Whose a waiting document is (C3, 9 November 2026; the dropdown and the
 * search, owner, 19 November 2026).
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
 *
 * The list is searched rather than scrolled, because the practice has a
 * hundred and fifty clients on file and a select of a hundred and fifty is a
 * list nobody can use. Typing narrows it; the match the parse suggests is
 * chosen already.
 *
 * "+ Add new client" is the last thing in the list rather than a button beside
 * it (owner, 19 November 2026), because choosing who it is and saying it is
 * nobody yet are the same decision, taken in the same place.
 */
export function WhoseDocument({
  docId,
  parsed,
  clients,
  counselors,
  offices,
  current = null,
}: {
  docId: string;
  parsed: Record<string, unknown>;
  clients: { id: string; name: string }[];
  counselors: Counselor[];
  offices: string[];
  /** Whose it is already, where somebody has said. Chosen to begin with. */
  current?: string | null;
}) {
  const [assignState, assign, assigning] = useActionState(assignDocument, initial);
  const [makeState, make, making] = useActionState(clientFromDocument, initial);

  const name = field(parsed, "clientName");
  const counselor = field(parsed, "counselorName");
  const office = field(parsed, "office");
  const agency = field(parsed, "agencyId");

  const guess = useMemo(() => bestMatch(name.value ?? "", clients), [name.value, clients]);
  const [chosen, setChosen] = useState(current ?? guess?.id ?? "");
  const [adding, setAdding] = useState(false);
  const [q, setQ] = useState("");

  /**
   * The list, narrowed by what has been typed - and whoever is chosen stays in
   * it whatever is typed, so the search cannot quietly empty the answer.
   */
  const showing = useMemo(() => {
    const needle = q.trim().toLowerCase();
    if (!needle) return clients;
    return clients.filter((c) => c.name.toLowerCase().includes(needle) || c.id === chosen);
  }, [clients, q, chosen]);

  // The counselor the PDF names, where the practice has them on file.
  const match = counselors.find(
    (c) => c.name.trim().toLowerCase() === (counselor.value ?? "").trim().toLowerCase(),
  );

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <Said state={assignState} />
      <Said state={makeState} />

      <form action={assign} className="row2" style={{ gap: 6, alignItems: "flex-end" }}>
        <input type="hidden" name="document_id" value={docId} />
        <label className="field" style={{ maxWidth: 220 }}>
          <span>Search the clients</span>
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Part of a name"
            aria-label="Search the clients"
          />
        </label>
        <label className="field" style={{ maxWidth: 280 }}>
          <span>Client</span>
          <select
            name="client_id"
            value={chosen}
            onChange={(e) => {
              if (e.target.value === "__new__") {
                setAdding(true);
                setChosen("");
                return;
              }
              setAdding(false);
              setChosen(e.target.value);
            }}
          >
            <option value="">Choose the client…</option>
            {showing.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
            <option value="__new__">+ Add new client</option>
          </select>
        </label>
        <button className="btn" disabled={assigning || !chosen}>
          {assigning ? "…" : "That is them"}
        </button>
      </form>
      {guess && !current && (
        <p className="lock" style={{ marginTop: -4 }}>
          {guess.name} is what the form reads as, so they are chosen already
        </p>
      )}
      {name.value && !guess && !current && (
        <p className="lock" style={{ marginTop: -4 }}>
          The form says {name.value}, who is not on file under that name
        </p>
      )}

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
