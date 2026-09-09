"use client";

import { useState, useActionState } from "react";
import Link from "next/link";
import {
  createEmployer,
  setEmployerStatus,
  createLead,
  setLeadStatus,
  createMatch,
  setMatchStatus,
  createPlacementFromMatch,
  type LeadState,
} from "./actions";
import { today, JOB_STATUSES } from "@/lib/constants";

const initial: LeadState = { error: null, ok: null };

export const LEAD_STATUSES = ["Open", "Submitted", "Interviewing", "Filled", "Closed"];
// One list, in lib/constants.ts — see the note there about the four copies.
export const MATCH_STATUSES = JOB_STATUSES;
export const EMPLOYER_STATUSES = ["Prospect", "Active partner", "Do not use"];

type Option = { id: string; name: string };

function Message({ state }: { state: LeadState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export function AddEmployerForm() {
  const [state, action, pending] = useActionState(createEmployer, initial);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button className="btn gold" onClick={() => setOpen(true)}>
        Add employer
      </button>
    );
  }

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <h3>Add employer</h3>
      <Message state={state} />
      <form action={action}>
        <div className="row2">
          <label className="field">
            Name
            <input name="name" required />
          </label>
          <label className="field">
            Industry
            <input name="industry" placeholder="Retail, warehousing, food service…" />
          </label>
          <label className="field">
            Relationship
            <select name="relationship_status" defaultValue="Prospect">
              {EMPLOYER_STATUSES.map((s) => (
                <option key={s}>{s}</option>
              ))}
            </select>
          </label>
        </div>
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Contact name
            <input name="contact_name" />
          </label>
          <label className="field">
            Phone
            <input name="contact_phone" />
          </label>
          <label className="field">
            Email
            <input name="contact_email" type="email" />
          </label>
        </div>
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" style={{ flex: 2 }}>
            Address
            <input name="address" />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Hiring pattern
            <input name="hiring_pattern" placeholder="e.g. hires seasonally, walk-ins welcome" />
          </label>
        </div>
        <label className="field" style={{ marginTop: 10 }}>
          Notes
          <textarea name="notes" rows={2} />
        </label>
        <div className="row2" style={{ marginTop: 12 }}>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Add employer"}
          </button>
          <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

export function EmployerStatusControl({
  employerId,
  status,
  canEdit,
}: {
  employerId: string;
  status: string;
  canEdit: boolean;
}) {
  const [state, action, pending] = useActionState(setEmployerStatus, initial);

  if (!canEdit) {
    return (
      <span className={"chip " + (status === "Do not use" ? "bad" : status === "Active partner" ? "ok" : "")}>
        {status}
      </span>
    );
  }

  return (
    <form action={action} style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
      <input type="hidden" name="employer_id" value={employerId} />
      <select name="relationship_status" defaultValue={status} style={{ maxWidth: 150 }}>
        {EMPLOYER_STATUSES.map((s) => (
          <option key={s}>{s}</option>
        ))}
      </select>
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Save"}
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</span>}
    </form>
  );
}

export function AddLeadForm({ employers, staff }: { employers: Option[]; staff: Option[] }) {
  const [state, action, pending] = useActionState(createLead, initial);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button className="btn gold" onClick={() => setOpen(true)}>
        Add opening
      </button>
    );
  }

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <h3>Add opening</h3>
      <Message state={state} />
      {employers.length === 0 ? (
        <div className="empty">Add an employer first — an opening belongs to one.</div>
      ) : (
        <form action={action}>
          <div className="row2">
            <label className="field">
              Employer
              <select name="employer_id" required defaultValue="">
                <option value="">— choose —</option>
                {employers.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="field" style={{ flex: 2 }}>
              Job title
              <input name="title" required />
            </label>
            <label className="field">
              Wage range
              <input name="wage_range" placeholder="$15–17/hr" />
            </label>
          </div>
          <div className="row2" style={{ marginTop: 10 }}>
            <label className="field">
              Hours/week
              <input name="hours_week" placeholder="20–30" />
            </label>
            <label className="field">
              Shift
              <input name="shift" placeholder="Days, swing, weekends" />
            </label>
            <label className="field">
              Source
              <input name="source" placeholder="Indeed, walk-in, employer call" />
            </label>
            <label className="field" style={{ maxWidth: 170 }}>
              Posted
              <input name="posted_date" type="date" defaultValue={today()} />
            </label>
            <label className="field">
              Owner
              <select name="owner_staff_id" defaultValue="">
                <option value="">Me</option>
                {staff.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <label className="field" style={{ marginTop: 10 }}>
            Requirements
            <textarea name="requirements" rows={2} placeholder="Lifting, licence, background check…" />
          </label>
          <div className="row2" style={{ marginTop: 12 }}>
            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Add opening"}
            </button>
            <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </div>
  );
}

export function LeadStatusControl({ leadId, status }: { leadId: string; status: string }) {
  const [state, action, pending] = useActionState(setLeadStatus, initial);

  return (
    <form action={action} style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
      <input type="hidden" name="lead_id" value={leadId} />
      <select name="status" defaultValue={status} style={{ maxWidth: 160 }}>
        {LEAD_STATUSES.map((s) => (
          <option key={s}>{s}</option>
        ))}
      </select>
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Save"}
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</span>}
    </form>
  );
}

export function AddMatchForm({ leadId, clients }: { leadId: string; clients: Option[] }) {
  const [state, action, pending] = useActionState(createMatch, initial);

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <h3>Put a client forward</h3>
      <Message state={state} />
      <form action={action}>
        <input type="hidden" name="lead_id" value={leadId} />
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            Client
            <select name="client_id" required defaultValue="">
              <option value="">— choose —</option>
              {clients.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            Where things stand
            <select name="status" defaultValue="Saved">
              {MATCH_STATUSES.map((s) => (
                <option key={s}>{s}</option>
              ))}
            </select>
          </label>
          <label className="field" style={{ flex: 2 }}>
            Notes
            <input name="notes" placeholder="Added to the client's note automatically" />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Adding…" : "Add"}
          </button>
        </div>
        <p className="lock" style={{ margin: "10px 0 0" }}>
          This writes a typed note on the client, so the job-search work shows on their record and
          fills the USOR 96 monthly report without being entered twice.
        </p>
      </form>
    </div>
  );
}

export function MatchRow({
  match,
  leadId,
}: {
  match: {
    id: string;
    client_id: string;
    client_name: string;
    status: string;
    applied_on: string | null;
    interview_on: string | null;
    decided_on: string | null;
    notes: string;
    placement_id: string | null;
  };
  leadId: string;
}) {
  const [statusState, statusAction, saving] = useActionState(setMatchStatus, initial);
  const [placeState, placeAction, placing] = useActionState(createPlacementFromMatch, initial);
  const [confirming, setConfirming] = useState(false);

  return (
    <tr>
      <td>
        <Link href={`/clients/${match.client_id}`} style={{ color: "inherit", fontWeight: 600 }}>
          {match.client_name}
        </Link>
        {match.notes && (
          <div style={{ fontSize: 12, color: "var(--muted)" }}>{match.notes}</div>
        )}
        {(statusState.error ?? placeState.error) && (
          <div style={{ color: "var(--bad)", fontSize: 12 }}>
            {statusState.error ?? placeState.error}
          </div>
        )}
      </td>
      <td>
        <form action={statusAction} style={{ display: "inline-flex", gap: 6 }}>
          <input type="hidden" name="match_id" value={match.id} />
          <input type="hidden" name="lead_id" value={leadId} />
          <select name="status" defaultValue={match.status} style={{ maxWidth: 145 }}>
            {MATCH_STATUSES.map((s) => (
              <option key={s}>{s}</option>
            ))}
          </select>
          <button className="btn ghost" type="submit" disabled={saving}>
            {saving ? "…" : "Save"}
          </button>
        </form>
      </td>
      <td style={{ fontSize: 12, color: "var(--muted)", whiteSpace: "nowrap" }}>
        {match.applied_on && <div>applied {match.applied_on}</div>}
        {match.interview_on && <div>interview {match.interview_on}</div>}
        {match.decided_on && <div>decided {match.decided_on}</div>}
      </td>
      <td>
        {match.placement_id ? (
          <Link
            href={`/clients/${match.client_id}?tab=placements`}
            className="chip ok"
            style={{ textDecoration: "none" }}
          >
            placement recorded
          </Link>
        ) : match.status === "Hired" ? (
          confirming ? (
            <form action={placeAction}>
              <input type="hidden" name="match_id" value={match.id} />
              <input type="hidden" name="lead_id" value={leadId} />
              <div className="row2" style={{ gap: 6, alignItems: "center" }}>
                <label className="field" style={{ marginBottom: 0, maxWidth: 160 }}>
                  Start date
                  <input name="start_date" type="date" max={today()} defaultValue={today()} />
                </label>
                <button className="btn gold" type="submit" disabled={placing}>
                  {placing ? "Creating…" : "Create placement"}
                </button>
                <button className="btn ghost" type="button" onClick={() => setConfirming(false)}>
                  Not yet
                </button>
              </div>
              <p className="lock" style={{ margin: "6px 0 0", maxWidth: 320 }}>
                This starts the 30/60/90 retention checks USOR measures, and the placement fee is
                submitted from there.
              </p>
            </form>
          ) : (
            <button className="btn ghost" onClick={() => setConfirming(true)}>
              Create placement…
            </button>
          )
        ) : (
          <span className="lock">—</span>
        )}
      </td>
    </tr>
  );
}
