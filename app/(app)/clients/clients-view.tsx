"use client";

import { useState, useActionState } from "react";
import { addClient, type ClientFormState } from "./actions";
import { FUNDING_SOURCES } from "@/lib/constants";

type Option = { id: string; name: string };

const initial: ClientFormState = { error: null, ok: null };

/**
 * Adding a client. The list itself is server-rendered — filtering and sorting
 * happen in the URL — so this is the only part of the screen that needs to be
 * interactive.
 */
export function AddClientPanel({
  counselors,
  staff,
  offices,
}: {
  counselors: Option[];
  staff: Option[];
  offices: string[];
}) {
  const [adding, setAdding] = useState(false);
  const [state, action, pending] = useActionState(addClient, initial);

  return (
    <>
      <div className="row2" style={{ justifyContent: "flex-end", marginBottom: 8 }}>
        <button className="btn gold" onClick={() => setAdding(!adding)}>
          {adding ? "Cancel" : "Add client"}
        </button>
      </div>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {adding && (
        <div className="card" style={{ marginBottom: 14 }}>
          <form action={action}>
            <div className="row2">
              <label className="field">
                Full name
                <input name="name" required />
              </label>
              <label className="field">
                Agency client ID
                <input name="agency_id" />
              </label>
              <label className="field">
                Funding source
                <select name="funding_source" defaultValue="Utah VR">
                  {FUNDING_SOURCES.map((x) => (
                    <option key={x}>{x}</option>
                  ))}
                </select>
              </label>
            </div>

            <div className="row2" style={{ marginTop: 10 }}>
              <label className="field">
                Counselor
                <select name="counselor_id" defaultValue="">
                  <option value="">—</option>
                  {counselors.map((k) => (
                    <option key={k.id} value={k.id}>
                      {k.name}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                Counselor phone / fax
                <input name="counselor_contact" />
              </label>
              <label className="field">
                Referring office
                <select name="referring_office" defaultValue="">
                  <option value="">—</option>
                  {offices.map((o) => (
                    <option key={o}>{o}</option>
                  ))}
                </select>
              </label>
            </div>

            <div className="row2" style={{ marginTop: 10 }}>
              <label className="field">
                Caseload
                <input name="caseload" />
              </label>
              <label className="field">
                Unit
                <input name="unit" />
              </label>
              <label className="field">
                Assigned staff
                <select name="assigned_staff_id" defaultValue="">
                  <option value="">—</option>
                  {staff.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field" style={{ maxWidth: 220 }}>
                Date of birth
                <input name="dob" type="date" />
              </label>
            </div>

            <p className="lock" style={{ margin: "10px 0 0" }}>
              Date of birth is a restricted field — visible only to Admin, Intake &amp; Reports,
              and the assigned staff member.
            </p>

            <div className="row2" style={{ marginTop: 12 }}>
              <button className="btn" type="submit" disabled={pending}>
                {pending ? "Saving…" : "Save client"}
              </button>
              <span className="lock">
                Saving starts the client at Referral and raises the intake task for Job Search.
              </span>
            </div>
          </form>
        </div>
      )}
    </>
  );
}
