"use client";

import { useState, useActionState } from "react";
import { addClient, type ClientFormState } from "./actions";
import { FUNDING_SOURCES, SERVICE_TYPES, today } from "@/lib/constants";
import type { ServiceRate } from "@/lib/rate-schedule";

type Option = { id: string; name: string };

const initial: ClientFormState = { error: null, ok: null };

/**
 * A referral, in one step (owner, 3 November 2026, parts 2a and 2c).
 *
 * It was "Add client", and a referral arriving by hand took three screens:
 * the client here, then their authorization on Billing, then the counselor if
 * the counselor was new. The thing that actually arrives is a referral - a
 * person, who they are funded by, and the first thing the state has
 * authorized - so that is what this asks for, and the authorization half is
 * only shown to whoever may enter one.
 *
 * Two questions are new and neither can be skipped. A phone number, or the
 * tick that says there is not one and why: eight records on file have neither
 * and nobody can tell which of them was a shelter and which was a blank
 * field. And whether they may be texted, which used to be answered weeks
 * later by whoever first wanted to send one - asked here, with "not asked" as
 * an honest third answer rather than a default nobody chose.
 *
 * The list itself is server-rendered - filtering and sorting happen in the
 * URL - so this is the only part of the screen that needs to be interactive.
 */
export function AddClientPanel({
  counselors,
  staff,
  offices,
  rates,
  canBill,
}: {
  counselors: Option[];
  staff: Option[];
  offices: string[];
  /** From the rate schedule, so this form cannot price a service its own way. */
  rates: Record<string, ServiceRate>;
  /** Entering an authorization is Admin's and Billing's, here as anywhere. */
  canBill: boolean;
}) {
  const [adding, setAdding] = useState(false);
  const [state, action, pending] = useActionState(addClient, initial);
  const [noPhone, setNoPhone] = useState(false);
  const [withAuth, setWithAuth] = useState(false);
  const [service, setService] = useState("Job Coaching");
  const scheduled = rates[service];
  const [rateType, setRateType] = useState(scheduled?.rateType ?? "Hourly");

  return (
    <>
      <div className="row2" style={{ justifyContent: "flex-end", marginBottom: 8 }}>
        <button className="btn gold" onClick={() => setAdding(!adding)}>
          {adding ? "Cancel" : "Add referral"}
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
              {!noPhone && (
                <label className="field" style={{ maxWidth: 220 }}>
                  Phone
                  <input name="phone" type="tel" required autoComplete="off" />
                </label>
              )}
              <label className="row2" style={{ gap: 8, alignItems: "center", maxWidth: 160 }}>
                <input
                  type="checkbox"
                  name="no_phone"
                  checked={noPhone}
                  onChange={(e) => setNoPhone(e.target.checked)}
                />
                <span>No phone</span>
              </label>
              {noPhone && (
                <label className="field" style={{ flex: 2 }}>
                  Why there is not one
                  <input name="no_phone_reason" required autoComplete="off" />
                </label>
              )}
            </div>

            {!noPhone && (
              <fieldset className="field" style={{ marginTop: 10, border: 0, padding: 0 }}>
                <legend>Texting</legend>
                <div className="row2" style={{ gap: 14 }}>
                  {[
                    ["granted", "Yes"],
                    ["declined", "No"],
                    ["not_asked", "Not asked"],
                  ].map(([value, label]) => (
                    <label key={value} className="row2" style={{ gap: 6, alignItems: "center" }}>
                      <input type="radio" name="texting" value={value} required />
                      <span>{label}</span>
                    </label>
                  ))}
                </div>
              </fieldset>
            )}

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
                Job search staff
                <select name="assigned_staff_id" defaultValue="">
                  <option value="">—</option>
                  {staff.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                Billing staff
                <select name="billing_staff_id" defaultValue="">
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
              Date of birth is restricted to Admin, Reports and the assigned member.</p>

            {canBill && (
              <>
                <label className="row2" style={{ gap: 8, alignItems: "center", marginTop: 14 }}>
                  <input
                    type="checkbox"
                    name="with_authorization"
                    checked={withAuth}
                    onChange={(e) => setWithAuth(e.target.checked)}
                  />
                  <span>The first authorization came with it</span>
                </label>

                {withAuth && (
                  <>
                    <div className="row2" style={{ marginTop: 10 }}>
                      <label className="field">
                        Authorization number
                        <input name="number" placeholder="V10…" autoComplete="off" />
                      </label>
                      <label className="field">
                        Service
                        <select
                          name="service_type"
                          value={service}
                          onChange={(e) => {
                            setService(e.target.value);
                            const d = rates[e.target.value];
                            if (d) setRateType(d.rateType);
                          }}
                        >
                          {SERVICE_TYPES.map((x) => (
                            <option key={x}>{x}</option>
                          ))}
                        </select>
                      </label>
                      <label className="field" style={{ maxWidth: 170 }}>
                        Start
                        <input name="start_date" type="date" defaultValue={today()} />
                      </label>
                      <label className="field" style={{ maxWidth: 170 }}>
                        End
                        <input name="end_date" type="date" />
                      </label>
                    </div>

                    <div className="row2" style={{ marginTop: 10 }}>
                      <label className="field" style={{ maxWidth: 150 }}>
                        Priced
                        <select
                          name="rate_type"
                          value={rateType}
                          onChange={(e) => setRateType(e.target.value as "Hourly" | "Flat Fee")}
                        >
                          <option value="Flat Fee">As an amount</option>
                          <option value="Hourly">By the hour</option>
                        </select>
                      </label>
                      <label className="field" style={{ maxWidth: 150 }}>
                        {rateType === "Hourly" ? "Rate an hour ($)" : "Amount ($)"}
                        <input
                          name="rate"
                          type="number"
                          step="0.01"
                          key={service}
                          defaultValue={scheduled?.fee ?? ""}
                          required
                        />
                      </label>
                      {rateType === "Hourly" && (
                        <label className="field" style={{ maxWidth: 150 }}>
                          Hours
                          <input name="total_hours" type="number" step="0.25" required />
                        </label>
                      )}
                      <p className="lock" style={{ alignSelf: "end", margin: 0, flex: 1 }}>
                        {scheduled ? scheduled.basis : "The rate schedule does not price this service"}
                      </p>
                    </div>
                  </>
                )}
              </>
            )}

            <div className="row2" style={{ marginTop: 12 }}>
              <button className="btn" type="submit" disabled={pending}>
                {pending ? "Saving…" : "Save referral"}
              </button>
              <span className="lock">
                Saving starts them at Intake and raises the intake task.</span>
            </div>
          </form>
        </div>
      )}
    </>
  );
}
