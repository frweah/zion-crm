"use client";

import Link from "next/link";
import { useActionState } from "react";
import type { ReportLineOut } from "@/lib/report-text";
import {
  redraftMonth,
  reopenMonth,
  reviewMonth,
  saveMonthSummary,
  signMonth,
  type MonthState,
} from "../month-actions";

const initial: MonthState = { error: null, ok: null };

const day = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { day: "numeric", month: "short" });

const moment = (iso: string) =>
  new Date(iso).toLocaleString("en-US", {
    timeZone: "America/Denver",
    dateStyle: "medium",
    timeStyle: "short",
  });

export type MonthRow = {
  id: string;
  month: string;
  status: string;
  due_on: string;
  note: string;
  /** The summary the record would write for itself, offered where nobody has. */
  drafted: string;
  signed_at: string | null;
  signed_by_name: string;
  sent_at: string | null;
  sent_to: string;
  reopen_reason: string;
  pdf_attachment_id: string | null;
};

/**
 * The report, then what it rests on, then what can be done to it.
 *
 * In that order because that is the order somebody signs in: read it, see
 * whether the account behind it is any good, then act. The buttons are last
 * on the screen for the same reason they are last in the sentence.
 */
export function MonthReport({
  clientId,
  report,
  lines,
  weeks,
  gaps,
  canSign,
  counselorEmail,
}: {
  clientId: string;
  report: MonthRow;
  lines: ReportLineOut[];
  weeks: { week_start: string; status: string; note: string }[];
  gaps: { from: string; to: string }[];
  canSign: boolean;
  counselorEmail: string;
}) {
  const [saveState, save, saving] = useActionState(saveMonthSummary, initial);
  const [reviewState, review, reviewing] = useActionState(reviewMonth, initial);
  const [signState, sign, signing] = useActionState(signMonth, initial);
  const [reopenState, reopen, reopening] = useActionState(reopenMonth, initial);
  const [redraftState, redraft, redrafting] = useActionState(redraftMonth, initial);

  const trouble =
    saveState.error ?? reviewState.error ?? signState.error ?? reopenState.error ?? redraftState.error;
  const went = saveState.ok ?? reviewState.ok ?? signState.ok ?? reopenState.ok ?? redraftState.ok;

  const signed = report.status === "Signed" || report.status === "Sent";
  const sent = report.status === "Sent";
  const open = report.status === "Draft";

  const hidden = (
    <>
      <input type="hidden" name="month_id" value={report.id} />
      <input type="hidden" name="client_id" value={clientId} />
    </>
  );

  const unconfirmed = weeks.filter((w) => w.status !== "Confirmed").length;

  return (
    <>
      {/* ── the report ───────────────────────────────────────── */}
      <section className="page-section">
        <article className="card">
          {lines.map((line, i) =>
            line.as === "blank" ? (
              <div key={i} style={{ height: 10 }} />
            ) : line.as === "title" ? (
              <h2 className="h2" key={i}>
                {line.text}
              </h2>
            ) : line.as === "heading" ? (
              <p key={i}>
                <b>{line.text}</b>
              </p>
            ) : line.as === "label" ? (
              <h3 key={i} style={{ marginTop: 6 }}>
                {line.text}
              </h3>
            ) : line.as === "entry" ? (
              <div className="row2" key={i} style={{ gap: 10, alignItems: "baseline" }}>
                <span className="lock" style={{ minWidth: 72 }}>
                  {line.on ? day(line.on) : ""}
                </span>
                <span className="day-main">{line.text}</span>
              </div>
            ) : (
              <p key={i}>{line.text}</p>
            ),
          )}
        </article>
      </section>

      {/* ── what the account rests on ────────────────────────── */}
      <section className="page-section">
        <h2 className="h2">Weeks behind it</h2>
        <div className="card" data-layout="why">
          {weeks.length === 0 ? (
            <p className="empty">
              No week was kept for this month — everything above was read off the record.
            </p>
          ) : (
            weeks.map((w) => (
              <div className="row2" key={w.week_start} style={{ gap: 10, alignItems: "baseline" }}>
                <span className="lock" style={{ minWidth: 92 }}>
                  {day(w.week_start)}
                </span>
                <span className={"chip " + (w.status === "Confirmed" ? "ok" : "warn")}>
                  {w.status}
                </span>
                <span className="day-main">{w.note || "Nothing written for the week"}</span>
              </div>
            ))
          )}
          {gaps.map((g) => (
            <p className="lock" key={g.from}>
              {day(g.from)} to {day(g.to)} — nobody kept a week, read off the record
            </p>
          ))}
        </div>
        {unconfirmed > 0 && !signed && (
          <p className="alert warn">
            {unconfirmed} of these {weeks.length} weeks has not been confirmed by whoever did the
            work
          </p>
        )}
      </section>

      {trouble && <p className="alert bad">{trouble}</p>}
      {went && !trouble && <p className="alert ok">{went}</p>}

      {/* ── and what can be done to it ───────────────────────── */}
      <section className="page-section">
        <h2 className="h2">Summary and signature</h2>

        {sent ? (
          <div className="card">
            <p>
              Sent to {report.sent_to}
              {report.sent_at ? ` on ${moment(report.sent_at)}` : ""}, signed by{" "}
              {report.signed_by_name || "the practice"}.
            </p>
            {report.pdf_attachment_id && (
              <Link className="btn ghost" href={`/clients/${clientId}?tab=documents`}>
                The signed PDF
              </Link>
            )}
          </div>
        ) : signed ? (
          <div className="card">
            <p>
              Signed by {report.signed_by_name || "the practice"}
              {report.signed_at ? ` on ${moment(report.signed_at)}` : ""}. The weeks it was
              assembled from are held until it is reopened.
            </p>
            <div className="row2" style={{ gap: 8, marginTop: 10 }}>
              {canSign && counselorEmail && (
                <Link
                  className="btn gold"
                  href={`/mail/compose?client=${clientId}&report=${report.id}`}
                  style={{ textDecoration: "none" }}
                >
                  Send it
                </Link>
              )}
              {report.pdf_attachment_id && (
                <Link className="btn ghost" href={`/clients/${clientId}?tab=documents`}>
                  The signed PDF
                </Link>
              )}
            </div>
            {canSign && !counselorEmail && (
              <p className="alert warn" style={{ marginTop: 10 }}>
                This client has no counselor email on the record — add one on the Profile tab
              </p>
            )}
            {canSign && (
              <form action={reopen} style={{ marginTop: 14 }}>
                {hidden}
                <label className="field">
                  Why it is being reopened
                  <input name="reason" maxLength={200} />
                </label>
                <button className="btn ghost" disabled={reopening}>
                  Reopen
                </button>
              </form>
            )}
          </div>
        ) : (
          <div className="card">
            {report.reopen_reason && (
              <p className="lock">Reopened: {report.reopen_reason}</p>
            )}
            <form action={review}>
              {hidden}
              <label className="field">
                Summary
                <textarea
                  name="note"
                  rows={5}
                  defaultValue={report.note || report.drafted}
                  readOnly={!canSign}
                />
              </label>
              {!report.note && (
                <p className="lock">
                  Drafted from the record — replace it with your own account
                </p>
              )}
              {canSign && (
                <div className="row2" style={{ gap: 8 }}>
                  <button className="btn ghost" formAction={save} disabled={saving}>
                    Save
                  </button>
                  {open && (
                    <button className="btn" disabled={reviewing}>
                      Mark read
                    </button>
                  )}
                  <button className="btn gold" formAction={sign} disabled={signing}>
                    Sign it
                  </button>
                </div>
              )}
            </form>
            {canSign && open && (
              <form action={redraft} style={{ marginTop: 10 }}>
                {hidden}
                <button className="btn ghost" disabled={redrafting}>
                  Assemble it again from the weeks
                </button>
              </form>
            )}
          </div>
        )}
      </section>
    </>
  );
}
