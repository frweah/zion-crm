"use client";

import { useActionState } from "react";
import { ROLE_NAMES, ROLE_LABEL, type Role } from "@/lib/roles";
import {
  editStaffIdentity,
  addStaffAlias,
  removeStaffAlias,
  type IdentityState,
} from "./identity-actions";

const initial: IdentityState = { error: null, ok: null };

function Said({ state }: { state: IdentityState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export type AliasRow = { id: string; address: string; note: string };

/**
 * Who somebody is (owner, 14 Oct 2026, item 4).
 *
 * The four fields this screen never had: the name, the address they sign in
 * with, their phone number and their role. Employment, pay, certifications
 * and documents are the cards below; these are the person.
 *
 * The note is offered rather than required. The log records the change
 * whether or not one is given - a field, from what to what, and whose record
 * it was - and a reason is the part only the person making it knows.
 */
export function IdentityPanel({
  person,
  aliases,
  isSelf,
}: {
  person: { id: string; name: string; email: string | null; phone: string | null; role: string };
  aliases: AliasRow[];
  isSelf: boolean;
}) {
  const [state, action, pending] = useActionState(editStaffIdentity, initial);
  const [addState, addAction, adding] = useActionState(addStaffAlias, initial);
  const [dropState, dropAction] = useActionState(removeStaffAlias, initial);

  return (
    <div className="card">
      <h3 style={{ marginTop: 0 }}>Who they are</h3>
      <p className="lock" style={{ marginTop: 0 }}>
        Every field here is yours to change, and every change is kept with your name on it.
        {isSelf ? " This is your own record." : " This is somebody else's record."}
      </p>

      <form action={action}>
        <Said state={state} />
        <input type="hidden" name="staff_id" value={person.id} />
        <div className="row2">
          <label className="field" htmlFor="id-name">
            Name
            <input id="id-name" name="name" defaultValue={person.name} required />
          </label>
          <label className="field" htmlFor="id-email">
            Signs in with
            <input id="id-email" name="email" type="email" defaultValue={person.email ?? ""} />
          </label>
          <label className="field" htmlFor="id-phone">
            Phone
            <input id="id-phone" name="phone" defaultValue={person.phone ?? ""} />
          </label>
          <label className="field" htmlFor="id-role">
            Role
            <select id="id-role" name="role" defaultValue={person.role}>
              {ROLE_NAMES.map((r) => (
                <option key={r} value={r}>
                  {ROLE_LABEL[r as Role]}
                </option>
              ))}
            </select>
          </label>
        </div>
        <div className="row2" style={{ marginTop: 10, alignItems: "flex-end" }}>
          <label className="field" htmlFor="id-note" style={{ flex: 2 }}>
            Why, if it is worth saying
            <input id="id-note" name="note" placeholder="Corrected from the signed offer letter" />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Save"}
          </button>
        </div>
      </form>

      {/* ── other addresses ──
          Changing the sign-in address above is how somebody signs in; this is
          every other address that reaches them. Rispah is written to at the
          practice address and signs in elsewhere, which is what this is for. */}
      <h4 style={{ marginBottom: 4 }}>Also written to at</h4>
      <p className="lock" style={{ marginTop: 0 }}>
        Mail to one of these reaches them. Adding one never changes how they sign in.
      </p>
      <Said state={addState} />
      <Said state={dropState} />
      {aliases.length > 0 && (
        <table
          className="t"
          data-layout="the other addresses that reach this person: the address, why it exists, and a way to remove it"
        >
          <tbody>
            {aliases.map((a) => (
              <tr key={a.id}>
                <td>{a.address}</td>
                <td className="lock">{a.note}</td>
                <td style={{ width: "1%" }}>
                  <form action={dropAction}>
                    <input type="hidden" name="staff_id" value={person.id} />
                    <input type="hidden" name="alias_id" value={a.id} />
                    <button className="btn ghost" type="submit">
                      Remove
                    </button>
                  </form>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <form action={addAction} className="row2" style={{ marginTop: 8, alignItems: "flex-end" }}>
        <input type="hidden" name="staff_id" value={person.id} />
        <label className="field" htmlFor="id-alias">
          Address
          <input id="id-alias" name="address" type="email" placeholder="name@zionvocrehab.com" />
        </label>
        <label className="field" htmlFor="id-alias-note" style={{ flex: 2 }}>
          Note
          <input id="id-alias-note" name="note" placeholder="Written to at the practice address" />
        </label>
        <button className="btn" type="submit" disabled={adding}>
          {adding ? "…" : "Add"}
        </button>
      </form>
    </div>
  );
}
