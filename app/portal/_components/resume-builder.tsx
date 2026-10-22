"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { saveResume, finishResume } from "../actions";
import {
  EMPTY_JOB,
  RESUME_STEPS,
  SKILL_IDEAS,
  SUMMARY_IDEAS,
  bullets,
  datesText,
  realJobs,
  resumeProblems,
  sectionOrder,
  SECTION_TITLE,
  type ResumeData,
  type ResumeJob,
} from "@/lib/portal/resume";

/**
 * The resume builder: one step a screen, most recent job first, saved after
 * every step. Each step's heading takes focus when it opens, so a screen
 * reader announces where the person is; every field has a visible label; and
 * nothing is signalled by colour alone.
 */

const MONTH_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];
const THIS_YEAR = new Date().getFullYear();
const YEARS = Array.from({ length: 50 }, (_, i) => String(THIS_YEAR - i));

function MonthField({
  id,
  legend,
  value,
  onChange,
}: {
  id: string;
  legend: string;
  value: string;
  onChange: (v: string) => void;
}) {
  const [y, m] = value ? value.split("-") : ["", ""];
  const set = (year: string, month: string) => onChange(year && month ? `${year}-${month}` : year ? `${year}-01` : "");
  return (
    <fieldset className="portal-field portal-month">
      <legend>{legend}</legend>
      <label htmlFor={`${id}-m`} className="sr-only">
        Month
      </label>
      <select id={`${id}-m`} value={m} onChange={(e) => set(y || String(THIS_YEAR), e.target.value)}>
        <option value="">Month</option>
        {MONTH_NAMES.map((name, i) => (
          <option key={name} value={String(i + 1).padStart(2, "0")}>
            {name}
          </option>
        ))}
      </select>
      <label htmlFor={`${id}-y`} className="sr-only">
        Year
      </label>
      <select id={`${id}-y`} value={y} onChange={(e) => set(e.target.value, m || "01")}>
        <option value="">Year</option>
        {YEARS.map((yr) => (
          <option key={yr}>{yr}</option>
        ))}
      </select>
    </fieldset>
  );
}

function Text({
  id,
  label,
  hint,
  value,
  onChange,
  type = "text",
  autoComplete,
  max = 100,
}: {
  id: string;
  label: string;
  hint?: string;
  value: string;
  onChange: (v: string) => void;
  type?: string;
  autoComplete?: string;
  max?: number;
}) {
  return (
    <div className="portal-field">
      <label htmlFor={id}>{label}</label>
      {hint && (
        <p id={`${id}-hint`} className="portal-hint">
          {hint}
        </p>
      )}
      <input
        id={id}
        type={type}
        value={value}
        maxLength={max}
        autoComplete={autoComplete}
        aria-describedby={hint ? `${id}-hint` : undefined}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
}

function Area({
  id,
  label,
  hint,
  value,
  onChange,
  max = 800,
}: {
  id: string;
  label: string;
  hint?: string;
  value: string;
  onChange: (v: string) => void;
  max?: number;
}) {
  return (
    <div className="portal-field">
      <label htmlFor={id}>{label}</label>
      {hint && (
        <p id={`${id}-hint`} className="portal-hint">
          {hint}
        </p>
      )}
      <textarea
        id={id}
        rows={5}
        value={value}
        maxLength={max}
        aria-describedby={hint ? `${id}-hint` : undefined}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
}

function JobFields({ job, prefix, onChange }: { job: ResumeJob; prefix: string; onChange: (j: ResumeJob) => void }) {
  const set = (patch: Partial<ResumeJob>) => onChange({ ...job, ...patch });
  return (
    <>
      <Text id={`${prefix}-title`} label="Job title" hint="For example: Cashier, Janitor, Stocker" value={job.title} onChange={(v) => set({ title: v })} />
      <Text id={`${prefix}-employer`} label="Employer" value={job.employer} onChange={(v) => set({ employer: v })} />
      <Text id={`${prefix}-city`} label="City" hint="For example: Salt Lake City, UT" value={job.city} onChange={(v) => set({ city: v })} max={80} />
      <MonthField id={`${prefix}-start`} legend="When did you start?" value={job.start} onChange={(v) => set({ start: v })} />
      <div className="portal-check">
        <input
          id={`${prefix}-current`}
          type="checkbox"
          checked={job.current}
          onChange={(e) => set({ current: e.target.checked, end: e.target.checked ? "" : job.end })}
        />
        <label htmlFor={`${prefix}-current`}>I still work here</label>
      </div>
      {!job.current && <MonthField id={`${prefix}-end`} legend="When did you finish?" value={job.end} onChange={(v) => set({ end: v })} />}
      <Area
        id={`${prefix}-duties`}
        label="What did you do there?"
        hint="One thing on each line. For example: Helped customers find items"
        value={job.duties}
        onChange={(v) => set({ duties: v })}
      />
    </>
  );
}

function Preview({ d }: { d: ResumeData }) {
  const contact = [d.contact.city, d.contact.phone, d.contact.email].filter(Boolean).join(" | ");
  return (
    <div className="portal-resume-preview" aria-label="Your resume">
      <p className="portal-resume-name">{d.contact.name || "Your name"}</p>
      {contact && <p>{contact}</p>}
      {sectionOrder(d).map((kind) => (
        <div key={kind}>
          <h3>{SECTION_TITLE[kind]}</h3>
          {kind === "summary" && <p>{d.summary}</p>}
          {kind === "jobs" &&
            realJobs(d).map((j, i) => (
              <div key={i}>
                <p>
                  <strong>{[j.title, [j.employer, j.city].filter(Boolean).join(", ")].filter(Boolean).join(" — ")}</strong>
                  {datesText(j) && <> · {datesText(j)}</>}
                </p>
                <ul>
                  {bullets(j.duties).map((b, k) => (
                    <li key={k}>{b}</li>
                  ))}
                </ul>
              </div>
            ))}
          {kind === "skills" && <p>{d.skills.join(", ")}</p>}
          {kind === "education" &&
            d.education
              .filter((e) => e.school || e.what)
              .map((e, i) => <p key={i}>{[e.what, e.school].filter(Boolean).join(" — ") + (e.year ? `, ${e.year}` : "")}</p>)}
          {kind === "certs" && (
            <ul>
              {d.certs
                .filter((c) => c.name)
                .map((c, i) => (
                  <li key={i}>{c.name + (c.year ? `, ${c.year}` : "")}</li>
                ))}
            </ul>
          )}
          {kind === "volunteer" &&
            d.volunteer
              .filter((v) => v.org || v.role)
              .map((v, i) => (
                <div key={i}>
                  <p>
                    <strong>{[v.role, v.org].filter(Boolean).join(" — ")}</strong>
                  </p>
                  <ul>
                    {bullets(v.duties).map((b, k) => (
                      <li key={k}>{b}</li>
                    ))}
                  </ul>
                </div>
              ))}
        </div>
      ))}
    </div>
  );
}

export function ResumeBuilder({
  initial,
  initialStep,
  status,
  returnNote,
}: {
  initial: ResumeData;
  initialStep: number;
  status: "None" | "Draft" | "Returned" | "Submitted" | "Approved";
  returnNote: string;
}) {
  const router = useRouter();
  const [d, setD] = useState<ResumeData>(initial);
  const [step, setStep] = useState(Math.min(initialStep, RESUME_STEPS.length - 1));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [editing, setEditing] = useState(status !== "Submitted" && status !== "Approved");
  const [newSkill, setNewSkill] = useState("");
  const heading = useRef<HTMLHeadingElement>(null);
  const first = useRef(true);

  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    heading.current?.focus();
  }, [step, editing]);

  const set = (patch: Partial<ResumeData>) => setD((cur) => ({ ...cur, ...patch }));
  const jobs = d.jobs.length ? d.jobs : [{ ...EMPTY_JOB }];
  const setJob = (i: number, j: ResumeJob) => {
    const next = [...jobs];
    next[i] = j;
    set({ jobs: next });
  };

  async function go(to: number) {
    setBusy(true);
    setError(null);
    // With no jobs, the earlier-jobs step has nothing to ask.
    let target = to;
    if (target === 2 && d.noJobs) target = to > step ? 3 : 1;
    const saved = await saveResume(d, target);
    setBusy(false);
    if (saved.error) {
      setError(saved.error);
      return;
    }
    setStep(target);
  }

  async function finish() {
    setBusy(true);
    setError(null);
    const result = await finishResume(d);
    setBusy(false);
    if (result.error) {
      setError(result.error);
      return;
    }
    setDone(result.ok ?? "Sent.");
    router.refresh();
  }

  if (done) {
    return (
      <p className="portal-notice" role="status">
        {done}
      </p>
    );
  }

  if (!editing) {
    return (
      <>
        <p className="portal-notice" role="status">
          {status === "Submitted"
            ? "Your resume is with Zion. They will look at it and let you know."
            : "Zion has approved your resume. You can make a new version any time."}
        </p>
        <Preview d={d} />
        {status === "Approved" && (
          <div className="portal-actions">
            <button className="btn" type="button" onClick={() => { setEditing(true); setStep(0); }}>
              Make changes
            </button>
          </div>
        )}
      </>
    );
  }

  const problems = resumeProblems(d);
  const last = RESUME_STEPS.length - 1;

  return (
    <>
      {status === "Returned" && returnNote && (
        <p className="portal-notice">
          <strong>Zion asked for a change:</strong> {returnNote}
        </p>
      )}
      <p className="portal-hint">
        Step {step + 1} of {RESUME_STEPS.length}. Your answers are saved each time you continue.
      </p>
      <section className="portal-card" aria-labelledby="step-heading">
        <h2 id="step-heading" ref={heading} tabIndex={-1}>
          {RESUME_STEPS[step]}
        </h2>

        {step === 0 && (
          <>
            <Text id="c-name" label="Your name" value={d.contact.name} autoComplete="name" max={80}
              onChange={(v) => set({ contact: { ...d.contact, name: v } })} />
            <Text id="c-phone" label="Phone number" type="tel" value={d.contact.phone} autoComplete="tel" max={30}
              onChange={(v) => set({ contact: { ...d.contact, phone: v } })} />
            <Text id="c-email" label="Email address" type="email" value={d.contact.email} autoComplete="email" max={120}
              onChange={(v) => set({ contact: { ...d.contact, email: v } })} />
            <Text id="c-city" label="City and state" hint="For example: West Valley City, UT. Not your street address."
              value={d.contact.city} max={80} onChange={(v) => set({ contact: { ...d.contact, city: v } })} />
          </>
        )}

        {step === 1 && (
          <>
            <fieldset className="portal-field">
              <legend>Have you had a job before?</legend>
              <label className="portal-choice">
                <input type="radio" name="has-job" checked={!d.noJobs} onChange={() => set({ noJobs: false })} /> Yes
              </label>
              <label className="portal-choice">
                <input type="radio" name="has-job" checked={d.noJobs} onChange={() => set({ noJobs: true })} /> No, I have
                not had a job yet
              </label>
            </fieldset>
            {d.noJobs ? (
              <p>That is fine. Your resume will lead with your skills, training and volunteer work.</p>
            ) : (
              <>
                <p>Start with your most recent job, or the one you have now.</p>
                <JobFields job={jobs[0]} prefix="job0" onChange={(j) => setJob(0, j)} />
              </>
            )}
          </>
        )}

        {step === 2 && (
          <>
            {jobs.length === 1 && <p>Add any jobs you had before that one, newest first. You can skip this step.</p>}
            {jobs.slice(1).map((j, i) => (
              <div key={i} className="portal-subcard">
                <h3>Earlier job {i + 1}</h3>
                <JobFields job={j} prefix={`job${i + 1}`} onChange={(next) => setJob(i + 1, next)} />
                <button className="btn ghost" type="button" onClick={() => set({ jobs: jobs.filter((_, k) => k !== i + 1) })}>
                  Remove this job
                </button>
              </div>
            ))}
            {jobs.length < 8 && (
              <button className="btn ghost" type="button" onClick={() => set({ jobs: [...jobs, { ...EMPTY_JOB }] })}>
                Add an earlier job
              </button>
            )}
          </>
        )}

        {step === 3 && (
          <>
            <p>Schools, a diploma or GED, and any training programs. You can skip this step.</p>
            {d.education.map((e, i) => (
              <div key={i} className="portal-subcard">
                <Text id={`ed${i}-what`} label="What you earned or studied" hint="For example: High school diploma, GED, Forklift training"
                  value={e.what} max={120} onChange={(v) => set({ education: d.education.map((x, k) => (k === i ? { ...x, what: v } : x)) })} />
                <Text id={`ed${i}-school`} label="School or program" value={e.school} max={120}
                  onChange={(v) => set({ education: d.education.map((x, k) => (k === i ? { ...x, school: v } : x)) })} />
                <Text id={`ed${i}-year`} label="Year finished" hint="Leave empty if you are still there" value={e.year} max={4}
                  onChange={(v) => set({ education: d.education.map((x, k) => (k === i ? { ...x, year: v.replace(/\D/g, "") } : x)) })} />
                <button className="btn ghost" type="button" onClick={() => set({ education: d.education.filter((_, k) => k !== i) })}>
                  Remove
                </button>
              </div>
            ))}
            {d.education.length < 6 && (
              <button className="btn ghost" type="button" onClick={() => set({ education: [...d.education, { school: "", what: "", year: "" }] })}>
                Add school or training
              </button>
            )}
          </>
        )}

        {step === 4 && (
          <>
            <p>For example a food handler permit, a driver license or CPR. You can skip this step.</p>
            {d.certs.map((c, i) => (
              <div key={i} className="portal-subcard">
                <Text id={`ce${i}-name`} label="Certificate or license" value={c.name} max={120}
                  onChange={(v) => set({ certs: d.certs.map((x, k) => (k === i ? { ...x, name: v } : x)) })} />
                <Text id={`ce${i}-year`} label="Year" value={c.year} max={4}
                  onChange={(v) => set({ certs: d.certs.map((x, k) => (k === i ? { ...x, year: v.replace(/\D/g, "") } : x)) })} />
                <button className="btn ghost" type="button" onClick={() => set({ certs: d.certs.filter((_, k) => k !== i) })}>
                  Remove
                </button>
              </div>
            ))}
            {d.certs.length < 10 && (
              <button className="btn ghost" type="button" onClick={() => set({ certs: [...d.certs, { name: "", year: "" }] })}>
                Add a certificate or license
              </button>
            )}
          </>
        )}

        {step === 5 && (
          <>
            <fieldset className="portal-field">
              <legend>Choose the skills you have</legend>
              {[...new Set([...SKILL_IDEAS, ...d.skills])].map((s) => (
                <label key={s} className="portal-choice">
                  <input
                    type="checkbox"
                    checked={d.skills.includes(s)}
                    onChange={(e) => set({ skills: e.target.checked ? [...d.skills, s] : d.skills.filter((x) => x !== s) })}
                  />{" "}
                  {s}
                </label>
              ))}
            </fieldset>
            <Text id="new-skill" label="Add a skill of your own" value={newSkill} max={60} onChange={setNewSkill} />
            <button
              className="btn ghost"
              type="button"
              onClick={() => {
                const s = newSkill.trim();
                if (s && !d.skills.includes(s) && d.skills.length < 30) set({ skills: [...d.skills, s] });
                setNewSkill("");
              }}
            >
              Add this skill
            </button>
          </>
        )}

        {step === 6 && (
          <>
            <p>
              {d.noJobs
                ? "Volunteer work counts. Church, school, family or community help all belong here."
                : "Any volunteer work. You can skip this step."}
            </p>
            {d.volunteer.map((v, i) => (
              <div key={i} className="portal-subcard">
                <Text id={`vo${i}-role`} label="What you did" hint="For example: Food bank volunteer" value={v.role}
                  onChange={(x) => set({ volunteer: d.volunteer.map((y, k) => (k === i ? { ...y, role: x } : y)) })} />
                <Text id={`vo${i}-org`} label="Where" value={v.org}
                  onChange={(x) => set({ volunteer: d.volunteer.map((y, k) => (k === i ? { ...y, org: x } : y)) })} />
                <Area id={`vo${i}-duties`} label="Tasks" hint="One thing on each line" value={v.duties} max={600}
                  onChange={(x) => set({ volunteer: d.volunteer.map((y, k) => (k === i ? { ...y, duties: x } : y)) })} />
                <button className="btn ghost" type="button" onClick={() => set({ volunteer: d.volunteer.filter((_, k) => k !== i) })}>
                  Remove
                </button>
              </div>
            ))}
            {d.volunteer.length < 5 && (
              <button className="btn ghost" type="button" onClick={() => set({ volunteer: [...d.volunteer, { org: "", role: "", duties: "" }] })}>
                Add volunteer work
              </button>
            )}
          </>
        )}

        {step === 7 && (
          <>
            <fieldset className="portal-field">
              <legend>Start from an example, then change it to sound like you</legend>
              {SUMMARY_IDEAS.map((s, i) => (
                <label key={i} className="portal-choice">
                  <input type="radio" name="summary-idea" checked={d.summary === s} onChange={() => set({ summary: s })} /> {s}
                </label>
              ))}
            </fieldset>
            <Area id="summary" label="Your summary" hint="Two or three sentences about you as a worker. You can leave it empty."
              value={d.summary} max={600} onChange={(v) => set({ summary: v })} />
          </>
        )}

        {step === last && (
          <>
            <p>This is your resume. Go back to change anything.</p>
            <Preview d={d} />
            {problems.length > 0 && (
              <div role="alert">
                <p>
                  <strong>Before you finish:</strong>
                </p>
                <ul>
                  {problems.map((p) => (
                    <li key={p}>{p}</li>
                  ))}
                </ul>
              </div>
            )}
          </>
        )}

        {error && (
          <p className="portal-error" role="alert">
            {error}
          </p>
        )}

        <div className="portal-actions">
          {step > 0 && (
            <button className="btn ghost" type="button" disabled={busy} onClick={() => go(step - 1)}>
              Back
            </button>
          )}
          {step < last ? (
            <button className="btn" type="button" disabled={busy} onClick={() => go(step + 1)}>
              {busy ? "Saving…" : "Save and continue"}
            </button>
          ) : (
            <button className="btn" type="button" disabled={busy || problems.length > 0} onClick={finish}>
              {busy ? "Making your resume…" : "Finish and send to Zion"}
            </button>
          )}
        </div>
      </section>
    </>
  );
}
