"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import { setStage, updateClient, updateRestricted, type DetailState } from "./actions";
import { STAGES, CLIENT_STATUSES } from "@/lib/constants";

const initial: DetailState = { error: null, ok: null };

type Option = { id: string; name: string };

/**
 * A counselor, as the counselor's own record holds them.
 *
 * The client's profile used to carry a "Counselor phone / fax" box, which was
 * the same fact written a second time - and the two disagreed (§11). It reads
 * the counselor record now and asks for nothing.
 */
type CounselorOption = Option & {
  email: string | null;
  phone: string | null;
  fax: string | null;
  office: string | null;
};

export type ClientDetail = {
  id: string;
  name: string;
  client_no: number | null;
  agency_id: string;
  funding_source: string;
  phone: string;
  email: string;
  counselor_id: string | null;
  referring_office: string;
  caseload: string;
  unit: string;
  schedule: string;
  target_jobs: string;
  preferred_locations: string;
  job_search_email: string;
  assigned_staff_id: string | null;
  billing_staff_id: string | null;
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
  isAdmin,
}: {
  client: ClientDetail;
  counselors: CounselorOption[];
  staff: Option[];
  offices: string[];
  canEdit: boolean;
  isAdmin: boolean;
}) {
  const [state, action, pending] = useActionState(updateClient, initial);

  const officeChoices = [...new Set([...offices, client.referring_office].filter(Boolean))];

  const [more, setMore] = useState(false);

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
            <select name="status" defaultValue={client.status} disabled={!isAdmin}>
              {CLIENT_STATUSES.map((s) => (
                <option key={s}>{s}</option>
              ))}
            </select>
            {!isAdmin && <span className="lock">Admin only</span>}
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
            {/* Two assignments (0121): the job search, and the billing. */}
            Job search staff
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
          <label className="field">
            Billing staff
            <select name="billing_staff_id" defaultValue={client.billing_staff_id ?? ""} disabled={!canEdit}>
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
          {/* Read from the counselor, never asked for here (§11). */}
          {(() => {
            const k = counselors.find((x) => x.id === client.counselor_id);
            if (!k) return null;
            const reach = [k.phone, k.fax ? `fax ${k.fax}` : null, k.email]
              .filter(Boolean)
              .join(" · ");
            return (
              <p className="lock" style={{ gridColumn: "1 / -1", margin: 0 }}>
                {reach || "No phone or email on this counselor's record."}{" "}
                <Link href="/directory" style={{ color: "var(--teal)" }}>
                  {reach ? "On the counselor's record" : "Add it to their record"}
                </Link>
              </p>
            );
          })()}
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

        {/* Essentials first (Rei, Oct 2026): the fields somebody opens a
            record to see are the ones on the screen, and the rest are a
            click away rather than a scroll. Open it and it stays open
            while this record is. */}
        {more ? (
          <>
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
                <option>Flexible</option>
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

          {/* From the job-search spreadsheet (0117). The alias's password is not kept in the CRM. */}
          <div className="row2" style={{ marginTop: 10 }}>
            <label className="field" style={{ flex: 2 }} htmlFor="client-preferred-locations">
              Will work in
              <input
                id="client-preferred-locations"
                name="preferred_locations"
                defaultValue={client.preferred_locations}
                placeholder="Towns or areas"
                disabled={!canEdit}
              />
            </label>
            <label className="field" style={{ flex: 2 }} htmlFor="client-job-search-email">
              Job-search email
              <input
                id="client-job-search-email"
                name="job_search_email"
                type="email"
                defaultValue={client.job_search_email}
                placeholder="The alias they apply from"
                disabled={!canEdit}
              />
            </label>
          </div>
          </>
        ) : (
          <button className="row-link" type="button" onClick={() => setMore(true)} style={{ marginTop: 12 }}>
            Show more details
          </button>
        )}

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
          Date of birth and address are visible only to Admin, Intake &amp; Client Reports, and this
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
