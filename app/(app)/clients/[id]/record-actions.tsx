"use client";

import { useActionState, useEffect, useState, type ReactNode } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { addTask, type DetailState } from "./actions";
import { logVisit, type VisitState } from "./visit-actions";
import { BillFlow, type BillOption } from "../../bill-flow";
import { today } from "@/lib/constants";

type Option = { id: string; name: string };

export type { BillOption };

export type VisitAuth = { id: string; label: string };
const initialTask: DetailState = { error: null, ok: null };
const initialVisit: VisitState = { error: null, ok: null };

/**
 * What you can do to a client, on the record, on every tab.
 *
 * The seven things the day is actually made of. Each one opens here with the
 * client already filled in, because the client is the thing you are holding -
 * going out to a feature screen and finding them again is where the note
 * stops getting written.
 *
 * Which ones appear depends on what is true of this client: no open
 * authorization, no visit to log and nothing to bill; no counselor on the
 * record, nobody to email.
 */
export function RecordActions({
  clientId,
  clientName,
  tab,
  staff,
  myId,
  canLogHours,
  visitAuths,
  bills,
  coachingCodes,
  counselorEmail,
  counselorName,
  agency,
  preparedBy,
  billingOffice,
}: {
  clientId: string;
  clientName: string;
  tab: string;
  staff: Option[];
  myId: string;
  canLogHours: boolean;
  visitAuths: VisitAuth[];
  bills: BillOption[];
  coachingCodes: string[];
  counselorEmail: string | null;
  counselorName: string;
  agency: string;
  preparedBy: string;
  billingOffice: string | null;
}) {
  return (
    <>
      {canLogHours && visitAuths.length > 0 && (
        <LogVisit clientId={clientId} auths={visitAuths} codes={coachingCodes} />
      )}
      {bills.length > 0 && (
        <ReportAndBill
          clientId={clientId}
          clientName={clientName}
          bills={bills}
          counselorName={counselorName}
          agency={agency}
          preparedBy={preparedBy}
          billingOffice={billingOffice}
        />
      )}
      <Link className="btn ghost" href={`/clients/${clientId}?tab=jobs`} style={{ textDecoration: "none" }}>
        Job update
      </Link>
      <Link className="btn ghost" href={`/clients/${clientId}?tab=messages`} style={{ textDecoration: "none" }}>
        Message
      </Link>
      {counselorEmail && (
        <Link className="btn ghost" href={`/mail/compose?client=${clientId}`} style={{ textDecoration: "none" }}>
          Email counselor
        </Link>
      )}
      <Link className="btn ghost" href={`/clients/${clientId}?tab=notes`} style={{ textDecoration: "none" }}>
        Add note
      </Link>
      <AddTask clientId={clientId} staff={staff} myId={myId} />
      {/* The eighth (owner, 20 Sept 2026): the progress report is a different
          thing from emailing the counselor - it is built from the record, not
          typed - and it was on this header before, so it is back on it. */}
      <Link
        className="btn ghost"
        href={`/clients/${clientId}?tab=${tab}&report=Weekly`}
        style={{ textDecoration: "none" }}
      >
        Send report
      </Link>
    </>
  );
}

/** The shell every one of these opens in, so they behave the same way. */
function Dialog({
  label,
  open,
  onClose,
  children,
}: {
  label: string;
  open: boolean;
  onClose: () => void;
  children: ReactNode;
}) {
  useEffect(() => {
    if (!open) return;
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [open, onClose]);

  if (!open) return null;
  return (
    <div className="record-dialog-scrim" onClick={onClose}>
      <div className="card record-dialog" role="dialog" aria-label={label} onClick={(e) => e.stopPropagation()}>
        <div className="row2" style={{ justifyContent: "space-between", alignItems: "center" }}>
          <h3 style={{ margin: 0 }}>{label}</h3>
          <button className="btn ghost" type="button" onClick={onClose}>
            Close
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

/**
 * A visit, logged against the authorization it is billable to.
 *
 * Against an authorization rather than loose, because that is what makes it
 * appear on USOR 95 and what makes it billable. Hours with no authorization
 * are somebody's time that nobody will ever be paid for.
 */
function LogVisit({ clientId, auths, codes }: { clientId: string; auths: VisitAuth[]; codes: string[] }) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState(logVisit, initialVisit);
  const router = useRouter();

  useEffect(() => {
    if (state.ok) {
      setOpen(false);
      router.refresh();
    }
  }, [state, router]);

  return (
    <>
      <button className="btn ghost" type="button" onClick={() => setOpen(true)}>
        Log a visit
      </button>
      <Dialog label="Log a visit" open={open} onClose={() => setOpen(false)}>
        {state.error && <div className="alert bad">{state.error}</div>}
        <form action={action} style={{ marginTop: 10 }}>
          <input type="hidden" name="client_id" value={clientId} />
          <label className="field">
            Against
            <select name="auth_id" required defaultValue={auths[0]?.id}>
              {auths.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.label}
                </option>
              ))}
            </select>
          </label>
          <div className="row2">
            <label className="field" style={{ maxWidth: 180 }}>
              Date
              <input name="date" type="date" defaultValue={today()} max={today()} required />
            </label>
            <label className="field" style={{ maxWidth: 140 }}>
              Hours
              <input name="hours" type="number" step="0.25" min="0.25" required autoFocus />
            </label>
          </div>
          {codes.length > 0 && (
            <div className="row2">
              <label className="field">
                What was done
                <select name="primary_code" defaultValue="">
                  <option value="">Not stated</option>
                  {codes.map((c) => (
                    <option key={c} value={c}>
                      {c}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                And also (optional)
                <select name="secondary_code" defaultValue="">
                  <option value="">Nothing else</option>
                  {codes.map((c) => (
                    <option key={c} value={c}>
                      {c}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          )}
          <label className="field">
            Notes
            <textarea name="notes" rows={3} placeholder="What happened, in the words USOR should read" />
          </label>
          <label style={{ fontSize: "var(--text-base)", display: "block", marginBottom: 10 }}>
            <input type="checkbox" name="non_billable" style={{ width: "auto", marginRight: 8 }} />
            Not billable — record the time without claiming for it
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Logging…" : "Log the visit"}
          </button>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            It goes onto the authorization straight away, and onto the USOR form when you bill for it.
          </p>
        </form>
      </Dialog>
    </>
  );
}

/**
 * Report & bill.
 *
 * Pick the authorization; the form it needs is already decided by the service
 * it is for, so there is nothing to choose from a list of templates. The form
 * opens pre-filled from the log, and signing and sending it is the forms
 * engine as it already was.
 */
/**
 * Report & bill, on the record.
 *
 * A dialog around the same three steps the screen at /billing/report shows -
 * one component, so what somebody sees does not depend on which door they
 * came through.
 */
function ReportAndBill({
  clientId,
  clientName,
  bills,
  counselorName,
  agency,
  preparedBy,
  billingOffice,
}: {
  clientId: string;
  clientName: string;
  bills: BillOption[];
  counselorName: string;
  agency: string;
  preparedBy: string;
  billingOffice: string | null;
}) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button className="btn gold" type="button" onClick={() => setOpen(true)}>
        Report &amp; bill
      </button>
      <Dialog label={`Report and bill for ${clientName}`} open={open} onClose={() => setOpen(false)}>
        {open && (
          <BillFlow
            clientId={clientId}
            bills={bills}
            counselorName={counselorName}
            agency={agency}
            preparedBy={preparedBy}
            billingOffice={billingOffice}
          />
        )}
      </Dialog>
    </>
  );
}

function AddTask({ clientId, staff, myId }: { clientId: string; staff: Option[]; myId: string }) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState(addTask, initialTask);
  const router = useRouter();

  useEffect(() => {
    if (state.ok) router.refresh();
  }, [state, router]);

  return (
    <>
      <button className="btn ghost" type="button" onClick={() => setOpen(true)}>
        Add task
      </button>
      <Dialog label="Add a task" open={open} onClose={() => setOpen(false)}>
        {state.error && <div className="alert bad">{state.error}</div>}
        {state.ok && <div className="alert ok">{state.ok}</div>}
        <form action={action} style={{ marginTop: 10 }}>
          <input type="hidden" name="id" value={clientId} />
          <label className="field">
            Task
            <input name="title" placeholder="What needs doing" required autoFocus />
          </label>
          <div className="row2">
            <label className="field" style={{ maxWidth: 190 }}>
              Due
              <input name="due" type="date" defaultValue={today()} />
            </label>
            <label className="field">
              Assign to
              <select name="assigned_staff_id" defaultValue={myId}>
                {staff.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Adding…" : "Add task"}
          </button>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            Open tasks show at the top of Activity; done ones join the feed.
          </p>
        </form>
      </Dialog>
    </>
  );
}
