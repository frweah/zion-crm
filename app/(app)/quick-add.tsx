"use client";

import { useActionState, useEffect, useState } from "react";
import { NOTE_TYPES, JOB_STATUSES } from "@/lib/constants";
import { QUICK_KINDS, type QuickKind } from "@/lib/quick-add";
import {
  quickAdd,
  quickAddOptions,
  jobsForClient,
  type QuickAddState,
} from "./quick-add-actions";

type Options = Awaited<ReturnType<typeof quickAddOptions>>;
type Job = Awaited<ReturnType<typeof jobsForClient>>[number];

/**
 * The "+" in the header.
 *
 * Six things people add all day, each asking for the client and the essentials
 * and nothing else. The lists are fetched the first time it is opened rather
 * than on every page — a button that costs two queries on every screen would
 * be a strange thing to add in the name of speed.
 */
export function QuickAdd() {
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState<QuickKind>("note");
  const [options, setOptions] = useState<Options | null>(null);
  const [clientId, setClientId] = useState("");
  const [jobs, setJobs] = useState<Job[] | null>(null);
  const [employerId, setEmployerId] = useState("");

  const [state, action, pending] = useActionState<QuickAddState, FormData>(quickAdd, {
    error: null,
    ok: null,
  });

  useEffect(() => {
    if (open && !options) quickAddOptions().then(setOptions);
  }, [open, options]);

  // The interview picker needs this client's jobs, and only then.
  useEffect(() => {
    if (kind !== "interview" || !clientId) {
      setJobs(null);
      return;
    }
    let live = true;
    jobsForClient(clientId).then((j) => live && setJobs(j));
    return () => {
      live = false;
    };
  }, [kind, clientId]);

  useEffect(() => {
    if (!open) return;
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [open]);

  const allowed = QUICK_KINDS.filter((k) => !options || options.kinds.includes(k.key));
  const current = QUICK_KINDS.find((k) => k.key === kind)!;
  const needsClient = kind !== "session";
  const today = options?.today ?? "";

  return (
    <>
      <button
        className="btn gold"
        type="button"
        onClick={() => setOpen(true)}
        title="Add a note, task, job, interview, placement or work session"
      >
        + Add
      </button>

      {open && (
      <div
        onClick={() => setOpen(false)}
        style={{
          position: "fixed",
          inset: 0,
          background: "rgba(0,0,0,.35)",
          zIndex: 40,
          display: "flex",
          alignItems: "flex-start",
          justifyContent: "center",
          padding: "6vh 16px",
          overflowY: "auto",
        }}
      >
        <div
          className="card"
          onClick={(e) => e.stopPropagation()}
          style={{ width: "min(560px, 100%)", zIndex: 41 }}
        >
          <div className="row2" style={{ justifyContent: "space-between" }}>
            <h3 style={{ margin: 0 }}>Quick add</h3>
            <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
              Close
            </button>
          </div>

          <div className="tabs" style={{ margin: "10px 0 0", flexWrap: "wrap" }}>
            {allowed.map((k) => (
              <a
                key={k.key}
                href="#"
                className={k.key === kind ? "on" : ""}
                onClick={(e) => {
                  e.preventDefault();
                  setKind(k.key);
                }}
              >
                {k.label}
              </a>
            ))}
          </div>
          <p className="lock" style={{ margin: "6px 0 12px" }}>
            {current.hint}
          </p>

          {state.error && <div className="alert bad">{state.error}</div>}
          {state.ok && <div className="alert ok">{state.ok}</div>}

          {!options ? (
            <p className="sub">Loading…</p>
          ) : (
            <form action={action}>
              <input type="hidden" name="what" value={kind} />

              {(needsClient || kind === "session") && (
                <label className="field">
                  Client{kind === "session" && " (optional)"}
                  <select
                    name="client_id"
                    value={clientId}
                    onChange={(e) => setClientId(e.target.value)}
                    required={needsClient}
                  >
                    <option value="">
                      {kind === "session" ? "Not about one client" : "Choose…"}
                    </option>
                    {options.clients.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.name}
                      </option>
                    ))}
                  </select>
                </label>
              )}

              {kind === "note" && (
                <>
                  <label className="field">
                    Type
                    <select name="type" defaultValue="Phone call">
                      {NOTE_TYPES.map((t) => (
                        <option key={t}>{t}</option>
                      ))}
                    </select>
                  </label>
                  <label className="field">
                    What happened
                    <textarea name="text" rows={4} required autoFocus />
                  </label>
                  <p className="lock">
                    Visible to Admin and Job Search, the same as a note added on the client. Change
                    that on their Notes tab.
                  </p>
                </>
              )}

              {kind === "task" && (
                <>
                  <label className="field">
                    Task
                    <input name="title" required autoFocus />
                  </label>
                  <label className="field">
                    Due
                    <input type="date" name="due" defaultValue={today} />
                  </label>
                  <p className="lock">Assigned to you unless you move it on the Tasks screen.</p>
                </>
              )}

              {kind === "job" && (
                <>
                  <label className="field">
                    Employer
                    <select
                      name="employer_id"
                      value={employerId}
                      onChange={(e) => setEmployerId(e.target.value)}
                      required
                    >
                      <option value="">Choose…</option>
                      {options.employers.map((e) => (
                        <option key={e.id} value={e.id}>
                          {e.name}
                        </option>
                      ))}
                      <option value="new">Somewhere new…</option>
                    </select>
                  </label>
                  {employerId === "new" && (
                    <label className="field">
                      New employer
                      <input name="new_employer" required />
                    </label>
                  )}
                  <label className="field">
                    Position
                    <input name="title" required />
                  </label>
                  <label className="field">
                    Where it has got to
                    <select name="status" defaultValue="Applied">
                      {JOB_STATUSES.map((s) => (
                        <option key={s}>{s}</option>
                      ))}
                    </select>
                  </label>
                  <p className="lock">
                    Goes on the leads board and the client&apos;s record — one pipeline, seen from
                    two ends.
                  </p>
                </>
              )}

              {kind === "interview" && (
                <>
                  {!clientId ? (
                    <p className="sub">Choose the client first.</p>
                  ) : jobs === null ? (
                    <p className="sub">Looking up their jobs…</p>
                  ) : jobs.length === 0 ? (
                    <p className="alert">
                      No job on this client to attach an interview to. Add the job first — an
                      interview belongs to a position, or the record ends up in two places.
                    </p>
                  ) : (
                    <>
                      <label className="field">
                        Which job
                        <select name="match_id" required>
                          {jobs.map((j) => (
                            <option key={j.id} value={j.id}>
                              {j.label}
                              {j.interview_on ? ` · already set for ${j.interview_on}` : ""}
                            </option>
                          ))}
                        </select>
                      </label>
                      <label className="field">
                        Interview date
                        <input type="date" name="interview_on" defaultValue={today} required />
                      </label>
                      <p className="lock">
                        Raises the prep reminder the day before, the interview-day reminder, and
                        the appointment itself.
                      </p>
                    </>
                  )}
                </>
              )}

              {kind === "placement" && (
                <>
                  <label className="field">
                    Employer
                    <input name="employer" required list="quick-employers" />
                    <datalist id="quick-employers">
                      {options.employers.map((e) => (
                        <option key={e.id} value={e.name} />
                      ))}
                    </datalist>
                  </label>
                  <label className="field">
                    Job title
                    <input name="title" />
                  </label>
                  <label className="field">
                    Start date
                    <input type="date" name="start_date" defaultValue={today} />
                  </label>
                  <p className="lock">
                    Wage, hours and the 30/60/90-day checks are added on the client&apos;s
                    Placements tab.
                  </p>
                </>
              )}

              {kind === "session" && (
                <>
                  <label className="field">
                    Day worked
                    <input type="date" name="worked_on" defaultValue={today} required />
                  </label>
                  <label className="field">
                    Hours
                    <input type="number" name="hours" step="0.25" min="0" required />
                  </label>
                  <label className="field">
                    What the time was spent on
                    <textarea name="description" rows={3} required />
                  </label>
                  <p className="lock">
                    Hours are append-only: a mistake is corrected by a replacement on the Hours
                    screen, never by an edit.
                  </p>
                </>
              )}

              {!(kind === "interview" && (!clientId || (jobs?.length ?? 0) === 0)) && (
                <div className="row2" style={{ marginTop: 12 }}>
                  <button className="btn gold" type="submit" disabled={pending}>
                    {pending ? "Saving…" : `Add ${current.label.toLowerCase()}`}
                  </button>
                  <span className="lock">
                    Saved to the same place the full screen writes to, under the same rules.
                  </span>
                </div>
              )}
            </form>
          )}
        </div>
      </div>
      )}
    </>
  );
}
