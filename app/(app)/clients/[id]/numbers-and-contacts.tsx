"use client";

import { useActionState, useState } from "react";
import {
  addClientContact,
  addClientPhone,
  editClientContact,
  recordNumberConsent,
  removeClientContact,
  removeClientPhone,
  setTextingNumber,
} from "./numbers-actions";
import type { DetailState } from "./actions";

const initial: DetailState = { error: null, ok: null };
const LABELS = ["Mobile", "Home", "Work", "Other"] as const;

export type ClientNumber = {
  phone: string;
  label: string;
  texts_here: boolean;
  whose: string;
  whose_name: string;
  relationship: string;
  phone_id: string | null;
  contact_id: string | null;
  state: string | null;
  since: string | null;
  method: string | null;
  can_text: boolean | null;
};

export type ClientContact = {
  id: string;
  name: string;
  relationship: string;
  phone: string | null;
  phone_label: string;
  email: string;
  receives_updates: boolean;
  may_speak_for: boolean;
  note: string;
};

function Said({ state }: { state: DetailState }) {
  if (state.error) return <p className="alert bad">{state.error}</p>;
  if (state.ok) return <p className="alert ok">{state.ok}</p>;
  return null;
}

/** Granted, declined, withdrawn, or nothing recorded — in one word. */
function consentChip(n: ClientNumber) {
  if (n.can_text) return <span className="chip ok">Yes</span>;
  if (!n.state) return <span className="chip warn">Not recorded</span>;
  return <span className="chip bad">{n.state}</span>;
}

/**
 * The numbers a client has, and the people around them (part A, 9 Nov 2026).
 *
 * One card, because they are one question. A person ringing about an
 * appointment wants to know which number to try, whether it may be texted,
 * and who else may be told — and those three answers were in three places:
 * the profile form, the consent panel, and nowhere.
 *
 * A contact is not a client. That is true in the database, where the row has
 * nowhere to put a caseload, and it has to be true here too: there is no
 * action on this card that makes a client out of a contact, and no link from
 * a contact to a client record that does not exist.
 */
export function NumbersAndContacts({
  clientId,
  clientName,
  numbers,
  contacts,
  canEdit,
}: {
  clientId: string;
  clientName: string;
  numbers: ClientNumber[];
  contacts: ClientContact[];
  canEdit: boolean;
}) {
  const [addPhoneState, addPhone, addingPhone] = useActionState(addClientPhone, initial);
  const [textingState, makeTexting, swapping] = useActionState(setTextingNumber, initial);
  const [removePhoneState, dropPhone] = useActionState(removeClientPhone, initial);
  const [consentState, recordConsent, recording] = useActionState(recordNumberConsent, initial);
  const [addContactState, addContact, addingContact] = useActionState(addClientContact, initial);
  const [editState, editContact, editing] = useActionState(editClientContact, initial);
  const [removeState, dropContact] = useActionState(removeClientContact, initial);

  const [consentFor, setConsentFor] = useState<string | null>(null);
  const [openContact, setOpenContact] = useState<string | null>(null);
  const [addingOne, setAddingOne] = useState(false);
  const [addingPerson, setAddingPerson] = useState(false);

  const mine = numbers.filter((n) => n.whose === "Client");
  const theirs = numbers.filter((n) => n.whose === "Contact");

  return (
    <div className="card">
      <h3>Numbers and contacts</h3>
      <Said state={addPhoneState} />
      <Said state={textingState} />
      <Said state={removePhoneState} />
      <Said state={consentState} />

      <table className="t" data-layout="the numbers this client has: which one texts go to, what each one is, and whether it may be texted">
        <thead>
          <tr>
            <th>Number</th>
            <th>What it is</th>
            <th>Texting</th>
            {canEdit && <th />}
          </tr>
        </thead>
        <tbody>
          {mine.length === 0 && (
            <tr>
              <td colSpan={canEdit ? 4 : 3} className="lock">
                Nothing on file — add the number the client answers on.
              </td>
            </tr>
          )}
          {mine.map((n) => (
            <tr key={n.phone}>
              <td style={{ whiteSpace: "nowrap" }}>
                {n.phone}
                {n.texts_here && <span className="chip" style={{ marginLeft: 6 }}>texts go here</span>}
              </td>
              <td className="lock">{n.label}</td>
              <td>{consentChip(n)}</td>
              {canEdit && (
                <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                  {!n.texts_here && (
                    <form action={makeTexting} style={{ display: "inline" }}>
                      <input type="hidden" name="id" value={clientId} />
                      <input type="hidden" name="phone" value={n.phone} />
                      <button className="btn ghost" disabled={swapping}>
                        Texts go here
                      </button>
                    </form>
                  )}
                  <button
                    type="button"
                    className="btn ghost"
                    style={{ marginLeft: 6 }}
                    onClick={() => setConsentFor(consentFor === n.phone ? null : n.phone)}
                  >
                    Record consent
                  </button>
                  {n.phone_id && (
                    <form action={dropPhone} style={{ display: "inline" }}>
                      <input type="hidden" name="id" value={clientId} />
                      <input type="hidden" name="phone_id" value={n.phone_id} />
                      <button className="btn ghost" style={{ marginLeft: 6 }}>
                        Take it off
                      </button>
                    </form>
                  )}
                </td>
              )}
            </tr>
          ))}
          {theirs.map((n) => (
            <tr key={n.phone}>
              <td style={{ whiteSpace: "nowrap" }}>{n.phone}</td>
              <td className="lock">
                {n.whose_name}
                {n.relationship ? ` · ${n.relationship}` : ""}
              </td>
              <td>{consentChip(n)}</td>
              {canEdit && (
                <td style={{ textAlign: "right" }}>
                  <button
                    type="button"
                    className="btn ghost"
                    onClick={() => setConsentFor(consentFor === n.phone ? null : n.phone)}
                  >
                    Record consent
                  </button>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>

      {canEdit && consentFor && (
        <form action={recordConsent} className="card" style={{ marginTop: 10 }}>
          <input type="hidden" name="id" value={clientId} />
          <input type="hidden" name="phone" value={consentFor} />
          <h4 className="h3">Texting consent for {consentFor}</h4>
          <div className="row2">
            <label className="field">
              <span>What they said</span>
              <select name="state" defaultValue="Granted">
                <option value="Granted">Granted</option>
                <option value="Declined">Declined</option>
                <option value="Withdrawn">Withdrawn</option>
              </select>
            </label>
            <label className="field">
              <span>How</span>
              <select name="method" defaultValue="Verbal">
                <option value="Verbal">Verbal</option>
                <option value="Intake form">Intake form</option>
                <option value="Text reply">Text reply</option>
                <option value="Written">Written</option>
              </select>
            </label>
            <label className="field" style={{ flex: 2 }}>
              <span>How it was given</span>
              <input name="note" placeholder="On the phone, 9 November, with Margaret" />
            </label>
          </div>
          <button className="btn" disabled={recording}>
            {recording ? "…" : "Record it"}
          </button>
        </form>
      )}

      {canEdit && (
        <div style={{ marginTop: 10 }}>
          {addingOne ? (
            <form action={addPhone} className="card">
              <input type="hidden" name="id" value={clientId} />
              <div className="row2">
                <label className="field">
                  <span>Number</span>
                  <input name="phone" placeholder="(801) 555-0101" required />
                </label>
                <label className="field">
                  <span>What it is</span>
                  <select name="label" defaultValue="Mobile">
                    {LABELS.map((l) => (
                      <option key={l} value={l}>
                        {l}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="field" style={{ flex: 2 }}>
                  <span>Note</span>
                  <input name="note" placeholder="Do not ring the work one after five" />
                </label>
              </div>
              <button className="btn" disabled={addingPhone}>
                {addingPhone ? "…" : "Add it"}
              </button>
              <button type="button" className="btn ghost" style={{ marginLeft: 6 }} onClick={() => setAddingOne(false)}>
                Leave it
              </button>
            </form>
          ) : (
            <button type="button" className="btn ghost" onClick={() => setAddingOne(true)}>
              Add a number
            </button>
          )}
        </div>
      )}

      <h4 className="h3" style={{ marginTop: 18 }}>
        Contacts
      </h4>
      <Said state={addContactState} />
      <Said state={editState} />
      <Said state={removeState} />

      {contacts.length === 0 ? (
        <p className="lock">
          Nobody yet — add the person who rings about {clientName.split(" ")[0]}.
        </p>
      ) : (
        <table className="t" data-layout="the people around this client: who they are, how to reach them, and what they are told">
          <thead>
            <tr>
              <th>Who</th>
              <th>Number</th>
              <th>Weekly update</th>
              <th>May speak for</th>
              {canEdit && <th />}
            </tr>
          </thead>
          <tbody>
            {contacts.map((t) => (
              <tr key={t.id}>
                <td>
                  {t.name}
                  <span className="lock"> · {t.relationship}</span>
                </td>
                <td style={{ whiteSpace: "nowrap" }}>
                  {t.phone ?? <span className="lock">none on file</span>}
                </td>
                <td>{t.receives_updates ? <span className="chip ok">Yes</span> : <span className="lock">no</span>}</td>
                <td>{t.may_speak_for ? <span className="chip">Yes</span> : <span className="lock">no</span>}</td>
                {canEdit && (
                  <td style={{ textAlign: "right" }}>
                    <button
                      type="button"
                      className="btn ghost"
                      onClick={() => setOpenContact(openContact === t.id ? null : t.id)}
                    >
                      Change
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {canEdit &&
        contacts
          .filter((t) => t.id === openContact)
          .map((t) => (
            <div key={t.id} className="card" style={{ marginTop: 10 }}>
              <form action={editContact}>
                <input type="hidden" name="id" value={clientId} />
                <input type="hidden" name="contact_id" value={t.id} />
                <div className="row2">
                  <label className="field">
                    <span>Name</span>
                    <input name="name" defaultValue={t.name} required />
                  </label>
                  <label className="field">
                    <span>Relationship</span>
                    <input name="relationship" defaultValue={t.relationship} required />
                  </label>
                  <label className="field">
                    <span>Number</span>
                    <input name="phone" defaultValue={t.phone ?? ""} />
                  </label>
                  <label className="field">
                    <span>What it is</span>
                    <select name="label" defaultValue={t.phone_label}>
                      {LABELS.map((l) => (
                        <option key={l} value={l}>
                          {l}
                        </option>
                      ))}
                    </select>
                  </label>
                </div>
                <div className="row2">
                  <label className="field" style={{ flex: 2 }}>
                    <span>Email</span>
                    <input name="email" type="email" defaultValue={t.email} />
                  </label>
                  <label className="field">
                    <span>Note</span>
                    <input name="note" defaultValue={t.note} />
                  </label>
                </div>
                <div className="row2">
                  <label>
                    <input type="checkbox" name="receives_updates" defaultChecked={t.receives_updates} /> Receives the
                    weekly update
                  </label>
                  <label>
                    <input type="checkbox" name="may_speak_for" defaultChecked={t.may_speak_for} /> May speak for the
                    client
                  </label>
                </div>
                <button className="btn" disabled={editing}>
                  {editing ? "…" : "Save"}
                </button>
              </form>
              <form action={dropContact} style={{ marginTop: 10 }}>
                <input type="hidden" name="id" value={clientId} />
                <input type="hidden" name="contact_id" value={t.id} />
                <label className="field">
                  <span>Take them off the record</span>
                  <input name="reason" placeholder="Asked not to be contacted again" required />
                </label>
                <button className="btn ghost">Take them off</button>
              </form>
            </div>
          ))}

      {canEdit && (
        <div style={{ marginTop: 10 }}>
          {addingPerson ? (
            <form action={addContact} className="card">
              <input type="hidden" name="id" value={clientId} />
              <div className="row2">
                <label className="field">
                  <span>Name</span>
                  <input name="name" required />
                </label>
                <label className="field">
                  <span>Relationship</span>
                  <input name="relationship" placeholder="daughter-in-law" required />
                </label>
                <label className="field">
                  <span>Number</span>
                  <input name="phone" placeholder="(801) 555-0101" />
                </label>
                <label className="field">
                  <span>What it is</span>
                  <select name="label" defaultValue="Mobile">
                    {LABELS.map((l) => (
                      <option key={l} value={l}>
                        {l}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
              <div className="row2">
                <label className="field" style={{ flex: 2 }}>
                  <span>Email</span>
                  <input name="email" type="email" />
                </label>
              </div>
              <div className="row2">
                <label>
                  <input type="checkbox" name="receives_updates" /> Receives the weekly update
                </label>
                <label>
                  <input type="checkbox" name="may_speak_for" /> May speak for the client
                </label>
              </div>
              <button className="btn" disabled={addingContact}>
                {addingContact ? "…" : "Add them"}
              </button>
              <button
                type="button"
                className="btn ghost"
                style={{ marginLeft: 6 }}
                onClick={() => setAddingPerson(false)}
              >
                Leave it
              </button>
            </form>
          ) : (
            <button type="button" className="btn ghost" onClick={() => setAddingPerson(true)}>
              Add a contact
            </button>
          )}
        </div>
      )}
    </div>
  );
}
