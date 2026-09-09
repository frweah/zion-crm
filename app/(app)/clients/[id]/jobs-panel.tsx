"use client";

import { useState, useActionState } from "react";
import Link from "next/link";
import {
  addClientJob,
  updateClientJob,
  removeClientJob,
  type JobState,
} from "./job-actions";
import { createPlacementFromMatch } from "../../leads/actions";
import { JOB_STATUSES, jobStatusTone } from "@/lib/constants";

const initial: JobState = { error: null, ok: null };

export type JobRow = {
  match_id: string;
  status: string;
  status_rank: number;
  applied_on: string | null;
  interview_on: string | null;
  follow_up_on: string | null;
  decided_on: string | null;
  outcome: string;
  notes: string;
  placement_id: string | null;
  lead_id: string;
  title: string;
  wage_range: string;
  location: string;
  employer_id: string;
  employer_name: string;
  contact_name: string;
  contact_phone: string;
  contact_email: string;
};

function Message({ state }: { state: JobState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

/** Creating the placement stays its own decision, as it is on the board. */
function CreatePlacement({ matchId }: { matchId: string }) {
  const [state, action, pending] = useActionState(createPlacementFromMatch, initial);
  const [asked, setAsked] = useState(false);

  if (!asked) {
    return (
      <button className="btn gold" type="button" onClick={() => setAsked(true)}>
        Create placement
      </button>
    );
  }

  return (
    <div className="alert">
      A placement carries the 30, 60 and 90 day retention checks USOR measures, and the placement
      fee. Create it?
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
      <div className="row2" style={{ gap: 6, marginTop: 8 }}>
        <form action={action} style={{ display: "inline" }}>
          <input type="hidden" name="match_id" value={matchId} />
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Creating…" : "Yes, create it"}
          </button>
        </form>
        <button className="btn ghost" type="button" onClick={() => setAsked(false)}>
          Not yet
        </button>
      </div>
    </div>
  );
}

function JobRowEditor({ job, clientId }: { job: JobRow; clientId: string }) {
  const [state, action, pending] = useActionState(updateClientJob, initial);
  const [remState, remAction, removing] = useActionState(removeClientJob, initial);
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState(job.status);

  return (
    <tr>
      <td>
        <b>{job.employer_name}</b>
        <div style={{ fontSize: 12, color: "var(--muted)" }}>
          {job.title}
          {job.location && ` · ${job.location}`}
          {job.wage_range && ` · ${job.wage_range}`}
        </div>
        {(job.contact_name || job.contact_phone) && (
          <div className="lock">
            {job.contact_name}
            {job.contact_phone && ` · ${job.contact_phone}`}
          </div>
        )}
        {job.outcome && <div style={{ fontSize: 12, marginTop: 2 }}>{job.outcome}</div>}
        <Message state={state} />
        {remState.error && (
          <div style={{ color: "var(--bad)", fontSize: 12 }}>{remState.error}</div>
        )}

        {open && (
          <form action={action} style={{ marginTop: 10 }}>
            <input type="hidden" name="match_id" value={job.match_id} />
            <input type="hidden" name="client_id" value={clientId} />
            <div className="row2">
              <label className="field">
                Status
                <select name="status" value={status} onChange={(e) => setStatus(e.target.value)}>
                  {JOB_STATUSES.map((s) => (
                    <option key={s} value={s}>
                      {s}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                Applied
                <input type="date" name="applied_on" defaultValue={job.applied_on ?? ""} />
              </label>
              <label className="field">
                Interview
                <input type="date" name="interview_on" defaultValue={job.interview_on ?? ""} />
              </label>
              <label className="field">
                Follow up
                <input type="date" name="follow_up_on" defaultValue={job.follow_up_on ?? ""} />
              </label>
            </div>
            <label className="field">
              How did it go?
              <input name="outcome" defaultValue={job.outcome} placeholder="The outcome, in a line" />
            </label>
            <label className="field">
              Notes
              <input name="notes" defaultValue={job.notes} />
            </label>
            <div className="row2" style={{ gap: 6 }}>
              <button className="btn" type="submit" disabled={pending}>
                {pending ? "Saving…" : "Save"}
              </button>
              <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
                Cancel
              </button>
            </div>
          </form>
        )}

        {open && (
          <form action={remAction} style={{ marginTop: 8 }}>
            <input type="hidden" name="match_id" value={job.match_id} />
            <input type="hidden" name="client_id" value={clientId} />
            <button className="btn ghost" type="submit" disabled={removing}>
              {removing ? "…" : "Remove this job"}
            </button>
          </form>
        )}
      </td>

      <td style={{ whiteSpace: "nowrap", verticalAlign: "top" }}>
        <span className={"chip " + jobStatusTone(job.status)}>{job.status}</span>
        <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 4 }}>
          {job.applied_on && <div>applied {job.applied_on}</div>}
          {job.interview_on && <div>interview {job.interview_on}</div>}
          {job.follow_up_on && <div>follow up {job.follow_up_on}</div>}
        </div>
      </td>

      <td style={{ textAlign: "right", whiteSpace: "nowrap", verticalAlign: "top" }}>
        {job.status === "Hired" && !job.placement_id && (
          <CreatePlacement matchId={job.match_id} />
        )}
        {job.placement_id && (
          <Link className="chip ok" href={`/clients/${clientId}?tab=placements`}>
            placed
          </Link>
        )}{" "}
        <button className="btn ghost" type="button" onClick={() => setOpen(!open)}>
          {open ? "Close" : "Edit"}
        </button>
      </td>
    </tr>
  );
}

function AddJob({
  clientId,
  employers,
}: {
  clientId: string;
  employers: { id: string; name: string }[];
}) {
  const [state, action, pending] = useActionState(addClientJob, initial);
  const [open, setOpen] = useState(false);
  const [newEmployer, setNewEmployer] = useState(false);

  if (!open) {
    return (
      <button className="btn" type="button" onClick={() => setOpen(true)}>
        + Add job
      </button>
    );
  }

  return (
    <div style={{ marginTop: 10 }}>
      <Message state={state} />
      <form action={action}>
        <input type="hidden" name="client_id" value={clientId} />

        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            Employer
            {newEmployer ? (
              <input name="new_employer" required placeholder="Name of the employer" />
            ) : (
              <select name="employer_id" required defaultValue="">
                <option value="" disabled>
                  Choose…
                </option>
                {employers.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.name}
                  </option>
                ))}
              </select>
            )}
            <button
              className="btn ghost"
              type="button"
              onClick={() => setNewEmployer(!newEmployer)}
              style={{ marginTop: 4 }}
            >
              {newEmployer ? "Choose from the directory instead" : "Not in the directory yet"}
            </button>
          </label>
          <label className="field" style={{ flex: 2 }}>
            Position
            <input name="title" required placeholder="What the job is" />
          </label>
          <label className="field">
            Status
            <select name="status" defaultValue="Saved">
              {JOB_STATUSES.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
          </label>
        </div>

        {newEmployer && (
          <div className="row2">
            <label className="field">
              Contact name
              <input name="contact_name" />
            </label>
            <label className="field">
              Contact phone
              <input name="contact_phone" />
            </label>
            <label className="field">
              Contact email
              <input name="contact_email" type="email" />
            </label>
          </div>
        )}

        <div className="row2">
          <label className="field">
            Applied
            <input type="date" name="applied_on" />
          </label>
          <label className="field">
            Interview
            <input type="date" name="interview_on" />
          </label>
          <label className="field">
            Follow up
            <input type="date" name="follow_up_on" />
          </label>
          <label className="field">
            Wage
            <input name="wage_range" placeholder="$16–18/hr" />
          </label>
          <label className="field">
            Where
            <input name="location" placeholder="Site, if not the main address" />
          </label>
        </div>

        <label className="field">
          Notes
          <input name="notes" />
        </label>

        <div className="row2" style={{ gap: 6 }}>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Adding…" : "Add job"}
          </button>
          <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
            Cancel
          </button>
        </div>
        <p className="lock" style={{ marginBottom: 0 }}>
          This goes on the leads board too — there is one pipeline, seen from two ends. Adding it
          writes a note on the record, as moving it along will.
        </p>
      </form>
    </div>
  );
}

/**
 * Jobs we have tried, on the client's own record.
 *
 * Under stage history, because the question "where is this person up to" and
 * the question "what have we tried" are asked together and were two screens
 * apart.
 */
export function JobsPanel({
  clientId,
  jobs,
  employers,
  canEdit,
}: {
  clientId: string;
  jobs: JobRow[];
  employers: { id: string; name: string }[];
  canEdit: boolean;
}) {
  const open = jobs.filter((j) => j.status !== "Hired" && j.status !== "Not selected");
  const closed = jobs.filter((j) => j.status === "Hired" || j.status === "Not selected");

  return (
    <div className="card" style={{ marginTop: 14, padding: 0 }}>
      <div style={{ padding: "16px 16px 0" }}>
        <h3 style={{ margin: 0 }}>Jobs we have tried</h3>
        <p className="sub" style={{ marginTop: 4 }}>
          {open.length} still going
          {closed.length > 0 && `, ${closed.length} finished`}.
        </p>
      </div>

      <table className="t">
        <tbody>
          {jobs.length === 0 && (
            <tr>
              <td className="empty">
                Nothing yet. Add the first job this client has applied for.
              </td>
            </tr>
          )}
          {[...open, ...closed].map((job) => (
            <JobRowEditor key={job.match_id} job={job} clientId={clientId} />
          ))}
        </tbody>
      </table>

      {canEdit && (
        <div style={{ padding: "0 16px 16px" }}>
          <AddJob clientId={clientId} employers={employers} />
        </div>
      )}
    </div>
  );
}
