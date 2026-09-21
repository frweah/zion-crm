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
import { JOB_STATUSES, JOB_DONE, INTERVIEW_KINDS, INTERVIEW_CONFIRMED, INTERVIEW_RESULTS, jobStatusTone } from "@/lib/constants";
import { DataTable } from "../../data-table";

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
  // The job-search spreadsheet's columns (0117).
  interview_time: string | null;
  interview_kind: string;
  interview_location: string;
  interview_confirmed: string;
  interview_result: string;
  requisition: string;
  posting_url: string;
  apply_url: string;
  hours_week: string;
  industry: string;
};

/** "14:30:00" as "2:30 pm". */
function clock(t: string | null): string {
  if (!t) return "";
  const [h, m] = t.split(":").map(Number);
  return `${((h + 11) % 12) + 1}:${String(m).padStart(2, "0")} ${h < 12 ? "am" : "pm"}`;
}

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
      {state.error && <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</div>}
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

/**
 * One job, and its editor when opened.
 *
 * An item in a list rather than a table row: the editor opens underneath the
 * job with a form of its own, which a table cell cannot hold sensibly.
 */
function JobItem({ job, clientId }: { job: JobRow; clientId: string }) {
  const [state, action, pending] = useActionState(updateClientJob, initial);
  const [remState, remAction, removing] = useActionState(removeClientJob, initial);
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState(job.status);

  return (
    <div>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <b>{job.employer_name}</b>
        <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>
          {job.title}
          {job.hours_week && ` · ${job.hours_week}`}
          {job.location && ` · ${job.location}`}
          {job.wage_range && ` · ${job.wage_range}`}
        </div>
        {(job.requisition || job.posting_url || job.apply_url) && (
          <div className="lock">
            {job.requisition && `Job ID ${job.requisition}`}
            {job.posting_url && (
              <>
                {job.requisition && " · "}
                <a href={job.posting_url} target="_blank" rel="noopener noreferrer">
                  posting
                </a>
              </>
            )}
            {job.apply_url && job.apply_url !== job.posting_url && (
              <>
                {" · "}
                <a href={job.apply_url} target="_blank" rel="noopener noreferrer">
                  application
                </a>
              </>
            )}
          </div>
        )}
        {job.interview_on && (
          <div style={{ fontSize: "var(--text-sm)", marginTop: 2 }}>
            Interview {job.interview_on}
            {job.interview_time && ` at ${clock(job.interview_time)}`}
            {job.interview_kind && ` · ${job.interview_kind.toLowerCase()}`}
            {job.interview_location && ` · ${job.interview_location}`}
            {job.interview_confirmed && (
              <span className={"chip " + (job.interview_confirmed === "Confirmed" ? "ok" : "warn")} style={{ marginLeft: 6 }}>
                {job.interview_confirmed === "Confirmed" ? "client confirmed" : "not confirmed"}
              </span>
            )}
            {job.interview_result && <span className="chip" style={{ marginLeft: 6 }}>{job.interview_result}</span>}
          </div>
        )}
        {(job.contact_name || job.contact_phone) && (
          <div className="lock">
            {job.contact_name}
            {job.contact_phone && ` · ${job.contact_phone}`}
          </div>
        )}
        {job.outcome && <div style={{ fontSize: "var(--text-sm)", marginTop: 2 }}>{job.outcome}</div>}
      </div>

      <div style={{ whiteSpace: "nowrap" }}>
        <span className={"chip " + jobStatusTone(job.status)}>{job.status}</span>
        <div style={{ fontSize: "var(--text-xs)", color: "var(--muted)", marginTop: 4 }}>
          {job.applied_on && <div>applied {job.applied_on}</div>}
          {job.interview_on && <div>interview {job.interview_on}{job.interview_time && ` ${clock(job.interview_time)}`}</div>}
          {job.follow_up_on && <div>follow up {job.follow_up_on}</div>}
        </div>
      </div>

      <div style={{ textAlign: "right", whiteSpace: "nowrap" }}>
        {job.status === "Hired" && !job.placement_id && (
          <CreatePlacement matchId={job.match_id} />
        )}
        {job.placement_id && (
          <Link className="chip ok" href={`/clients/${clientId}?tab=jobs`}>
            placed
          </Link>
        )}{" "}
        <button className="btn ghost" type="button" onClick={() => setOpen(!open)}>
          {open ? "Close" : "Edit"}
        </button>
      </div>
      </div>

        <Message state={state} />
        {remState.error && (
          <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{remState.error}</div>
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
            <div className="row2">
              <label className="field" htmlFor={`iv-time-${job.match_id}`}>
                Interview time
                <input id={`iv-time-${job.match_id}`} type="time" name="interview_time" defaultValue={job.interview_time?.slice(0, 5) ?? ""} />
              </label>
              <label className="field" htmlFor={`iv-kind-${job.match_id}`}>
                How
                <select id={`iv-kind-${job.match_id}`} name="interview_kind" defaultValue={job.interview_kind}>
                  <option value="">—</option>
                  {INTERVIEW_KINDS.map((k) => (
                    <option key={k}>{k}</option>
                  ))}
                </select>
              </label>
              <label className="field" htmlFor={`iv-conf-${job.match_id}`}>
                Client confirmed?
                <select id={`iv-conf-${job.match_id}`} name="interview_confirmed" defaultValue={job.interview_confirmed}>
                  <option value="">Not asked</option>
                  {INTERVIEW_CONFIRMED.map((k) => (
                    <option key={k}>{k}</option>
                  ))}
                </select>
              </label>
              <label className="field" htmlFor={`iv-res-${job.match_id}`}>
                Interview result
                <select id={`iv-res-${job.match_id}`} name="interview_result" defaultValue={job.interview_result}>
                  <option value="">—</option>
                  {INTERVIEW_RESULTS.map((k) => (
                    <option key={k}>{k}</option>
                  ))}
                </select>
              </label>
            </div>
            <label className="field" htmlFor={`iv-loc-${job.match_id}`}>
              Where the interview is
              <input id={`iv-loc-${job.match_id}`} name="interview_location" defaultValue={job.interview_location} placeholder="Address, or the video link" />
            </label>
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
    </div>
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

        <div className="row2">
          <label className="field">
            Job ID
            <input name="requisition" placeholder="Requisition #" />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Posting link
            <input name="posting_url" type="url" placeholder="https://" />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Application link
            <input name="apply_url" type="url" placeholder="https://" />
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
  const done = (s: string) => (JOB_DONE as readonly string[]).includes(s);
  const open = jobs.filter((j) => !done(j.status));
  const closed = jobs.filter((j) => done(j.status));
  // The spreadsheet counted applications week by week; so does this.
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);
  const thisWeek = jobs.filter((j) => j.applied_on && j.applied_on >= weekAgo).length;

  return (
    <section style={{ marginTop: 14 }}>
      <h2 className="h2">Jobs we have tried</h2>
      <p className="sub" style={{ marginTop: 4 }}>
        {open.length} still going
        {closed.length > 0 && `, ${closed.length} finished`}. {thisWeek} applied for in the last 7 days.
      </p>

      {jobs.length === 0 ? (
        <div className="empty">Nothing yet. Add the first job this client has applied for.</div>
      ) : (
        // A table so the jobs sort by status, employer or date; each keeps its
        // own editor in its row. Still going first, then finished, until sorted.
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="jobs"
            columns={[
              { key: "job", label: "Job", sortLabel: "Employer" },
              { key: "status", label: "Status" },
              { key: "applied", label: "Applied" },
              { key: "next", label: "Next date" },
            ]}
            rows={[...open, ...closed].map((job) => ({
              key: job.match_id,
              sort: {
                job: job.employer_name,
                status: job.status_rank,
                applied: job.applied_on,
                next: job.interview_on ?? job.follow_up_on,
              },
              text: [job.employer_name, job.title, job.location, job.status, job.outcome].filter(Boolean).join(" "),
              cells: {
                job: <JobItem job={job} clientId={clientId} />,
                status: <span className="chip">{job.status}</span>,
                applied: <span style={{ whiteSpace: "nowrap" }}>{job.applied_on ?? "—"}</span>,
                next: (
                  <span style={{ whiteSpace: "nowrap" }}>
                    {job.interview_on ? `interview ${job.interview_on}` : job.follow_up_on ? `follow up ${job.follow_up_on}` : "—"}
                  </span>
                ),
              },
            }))}
            empty="Nothing yet. Add the first job this client has applied for."
          />
        </div>
      )}

      {canEdit && (
        <div style={{ marginTop: 10 }}>
          <AddJob clientId={clientId} employers={employers} />
        </div>
      )}
    </section>
  );
}
