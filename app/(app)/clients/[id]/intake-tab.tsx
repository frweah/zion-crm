"use client";

import { useActionState } from "react";
import { saveIntake, type DetailState } from "./actions";
import { ORG } from "@/lib/roles";

const initial: DetailState = { error: null, ok: null };

const TRANSPORT = ["Own vehicle", "Public transit", "Rides from family", "Needs assistance"];

export type IntakeRow = {
  phone: string;
  email: string;
  address: string;
  emergency_name: string;
  emergency_phone: string;
  goals: string;
  availability: string;
  transportation: string;
  accommodations: string;
  submitted_at: string;
  updated_on: string | null;
};

export function IntakeTab({
  clientId,
  clientName,
  intake,
  visible,
  canEdit,
}: {
  clientId: string;
  clientName: string;
  intake: IntakeRow | null;
  visible: boolean;
  canEdit: boolean;
}) {
  const [state, action, pending] = useActionState(saveIntake, initial);

  if (!visible) {
    return (
      <div className="card">
        <h3>Intake</h3>
        <p className="lock" style={{ margin: 0 }}>
          The intake record carries accommodations, emergency contacts and address, so it is
          limited to Admin, Intake &amp; Reports, and this client&apos;s assigned staff member.
        </p>
      </div>
    );
  }

  const firstName = clientName.split(" ")[0];

  return (
    <div className="card">
      <h3>{intake ? "Intake on file" : "Intake"}</h3>

      <p className="sub" style={{ marginTop: 0 }}>
        Client contact line to give out: {ORG.clientPhone} · {ORG.email}
        {intake
          ? ` · on file since ${intake.submitted_at}${intake.updated_on ? `, updated ${intake.updated_on}` : ""}`
          : ""}
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <input type="hidden" name="id" value={clientId} />

        <div className="row2">
          <label className="field">
            Phone
            <input name="phone" defaultValue={intake?.phone ?? ""} disabled={!canEdit} />
          </label>
          <label className="field">
            Email
            <input name="email" type="email" defaultValue={intake?.email ?? ""} disabled={!canEdit} />
          </label>
        </div>

        <label className="field" style={{ marginTop: 10 }}>
          Address
          <input name="address" defaultValue={intake?.address ?? ""} disabled={!canEdit} />
        </label>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Emergency contact
            <input
              name="emergency_name"
              defaultValue={intake?.emergency_name ?? ""}
              disabled={!canEdit}
            />
          </label>
          <label className="field">
            Emergency phone
            <input
              name="emergency_phone"
              defaultValue={intake?.emergency_phone ?? ""}
              disabled={!canEdit}
            />
          </label>
        </div>

        <label className="field" style={{ marginTop: 10 }}>
          Employment goals
          <textarea name="goals" rows={2} defaultValue={intake?.goals ?? ""} disabled={!canEdit} />
        </label>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Availability
            <input
              name="availability"
              placeholder="days / hours"
              defaultValue={intake?.availability ?? ""}
              disabled={!canEdit}
            />
          </label>
          <label className="field">
            Transportation
            <select
              name="transportation"
              defaultValue={intake?.transportation ?? "Own vehicle"}
              disabled={!canEdit}
            >
              {TRANSPORT.map((t) => (
                <option key={t}>{t}</option>
              ))}
            </select>
          </label>
        </div>

        <label className="field" style={{ marginTop: 10 }}>
          Accommodations needed
          <textarea
            name="accommodations"
            rows={2}
            defaultValue={intake?.accommodations ?? ""}
            disabled={!canEdit}
          />
        </label>

        <label style={{ fontSize: 13, display: "block", marginTop: 12 }}>
          <input
            type="checkbox"
            name="consent_signed"
            style={{ width: "auto", marginRight: 6 }}
            defaultChecked={Boolean(intake)}
            disabled={!canEdit}
          />
          Client signed consent to services and release of information
        </label>

        {canEdit && (
          <div className="row2" style={{ marginTop: 14 }}>
            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Saving…" : intake ? "Update intake" : "Submit intake"}
            </button>
            <span className="lock">
              {intake
                ? "The consent box must stay checked."
                : `Submitting moves ${firstName} to Intake and raises the assessment task.`}
            </span>
          </div>
        )}
      </form>
    </div>
  );
}
