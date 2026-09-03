"use client";

import { useActionState } from "react";
import { setStage, updateClient, updateRestricted, type DetailState } from "./actions";

const initial: DetailState = { error: null, ok: null };

const STAGES = [
  "Referral",
  "Intake",
  "Assessment",
  "Job Development",
  "Placement",
  "Job Coaching",
  "Follow-Along",
  "Closed",
];

type Option = { id: string; name: string };

export type ClientDetail = {
  id: string;
  name: string;
  client_no: number | null;
  agency_id: string;
  funding_source: string;
  phone: string;
  email: string;
  counselor_id: string | null;
  counselor_contact: string;
  referring_office: string;
  caseload: string;
  unit: string;
  schedule: string;
  target_jobs: string;
  assigned_staff_id: string | null;
  status: string;
  stage: string;
  wsa_tier: number | null;
  wsa_completed: string | null;
  import_review: string;
};

function Message({ state }: { state: DetailState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export function StageControl({
  client,
  canEdit,
}: {
  client: ClientDetail;
  canEdit: boolean;
}) {
  const [state, action, pending] = useActionState(setStage, initial);

  return (
    <div className="card">
      <h3>Pipeline stage</h3>
      <Message state={state} />
      <form action={action} className="row2">
        <input type="hidden" name="id" value={client.id} />
        <label className="field">
          Stage
          <select name="stage" defaultValue={client.stage} disabled={!canEdit}>
            {STAGES.map((s) => (
              <option key={s}>{s}</option>
            ))}
          </select>
        </label>
        {canEdit && (
          <button className="btn" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Move stage"}
          </button>
        )}
      </form>
    </div>
  );
}

export function DetailsForm({
  client,
  counselors,
  staff,
  offices,
  canEdit,
}: {
  client: ClientDetail;
  counselors: Option[];
  staff: Option[];
  offices: string[];
  canEdit: boolean;
}) {
  const [state, action, pending] = useActionState(updateClient, initial);

  const officeChoices = [...new Set([...offices, client.referring_office].filter(Boolean))];

  return (
    <div className="card">
      <h3>Details</h3>
      <Message state={state} />
      <form action={action}>
        <input type="hidden" name="id" value={client.id} />

        <div className="row2">
          <label className="field">
            Full name
            <input name="name" defaultValue={client.name} disabled={!canEdit} required />
          </label>
          <label className="field">
            Agency client ID
            <input name="agency_id" defaultValue={client.agency_id} disabled={!canEdit} />
          </label>
          <label className="field">
            Status
            <select name="status" defaultValue={client.status} disabled={!canEdit}>
              <option>Active</option>
              <option>Closed</option>
            </select>
          </label>
        </div>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Phone
            <input name="phone" defaultValue={client.phone} disabled={!canEdit} />
          </label>
          <label className="field">
            Email
            <input name="email" type="email" defaultValue={client.email} disabled={!canEdit} />
          </label>
          <label className="field">
            Assigned staff
            <select
              name="assigned_staff_id"
              defaultValue={client.assigned_staff_id ?? ""}
              disabled={!canEdit}
            >
              <option value="">—</option>
              {staff.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </label>
        </div>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Counselor
            <select
              name="counselor_id"
              defaultValue={client.counselor_id ?? ""}
              disabled={!canEdit}
            >
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
            <input
              name="counselor_contact"
              defaultValue={client.counselor_contact}
              disabled={!canEdit}
            />
          </label>
          <label className="field">
            Referring office
            <select
              name="referring_office"
              defaultValue={client.referring_office}
              disabled={!canEdit}
            >
              <option value="">—</option>
              {officeChoices.map((o) => (
                <option key={o}>{o}</option>
              ))}
            </select>
          </label>
        </div>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Caseload
            <input name="caseload" defaultValue={client.caseload} disabled={!canEdit} />
          </label>
          <label className="field">
            Unit
            <input name="unit" defaultValue={client.unit} disabled={!canEdit} />
          </label>
          <label className="field">
            Schedule
            <select name="schedule" defaultValue={client.schedule} disabled={!canEdit}>
              <option value="">—</option>
              <option>FT</option>
              <option>PT</option>
              <option>FT / PT</option>
            </select>
          </label>
        </div>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            WSA tier
            <select
              name="wsa_tier"
              defaultValue={client.wsa_tier ? String(client.wsa_tier) : ""}
              disabled={!canEdit}
            >
              <option value="">—</option>
              <option value="1">Tier 1</option>
              <option value="2">Tier 2</option>
            </select>
          </label>
          <label className="field">
            WSA completed
            <input
              name="wsa_completed"
              type="date"
              defaultValue={client.wsa_completed ?? ""}
              disabled={!canEdit}
            />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Target jobs / employers
            <input name="target_jobs" defaultValue={client.target_jobs} disabled={!canEdit} />
          </label>
        </div>

        {canEdit && (
          <div style={{ marginTop: 12 }}>
            <button className="btn" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Save details"}
            </button>
          </div>
        )}
      </form>
    </div>
  );
}

export function RestrictedPanel({
  clientId,
  dob,
  address,
  visible,
  canEdit,
}: {
  clientId: string;
  dob: string | null;
  address: string;
  visible: boolean;
  canEdit: boolean;
}) {
  const [state, action, pending] = useActionState(updateRestricted, initial);

  if (!visible) {
    return (
      <div className="card">
        <h3>Restricted details</h3>
        <p className="lock" style={{ margin: 0 }}>
          Date of birth and address are visible only to Admin, Intake &amp; Reports, and this
          client&apos;s assigned staff member.
        </p>
      </div>
    );
  }

  return (
    <div className="card">
      <h3>Restricted details</h3>
      <Message state={state} />
      <form action={action}>
        <input type="hidden" name="id" value={clientId} />
        <div className="row2">
          <label className="field" style={{ maxWidth: 220 }}>
            Date of birth
            <input name="dob" type="date" defaultValue={dob ?? ""} disabled={!canEdit} />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Address
            <input name="address" defaultValue={address} disabled={!canEdit} />
          </label>
          {canEdit && (
            <button className="btn" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Save"}
            </button>
          )}
        </div>
      </form>
      <p className="lock" style={{ marginTop: 10, marginBottom: 0 }}>
        Restricted tier — the database limits these fields, not just this screen.
      </p>
    </div>
  );
}
