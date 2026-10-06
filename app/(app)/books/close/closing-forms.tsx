"use client";

import { useActionState, useState } from "react";
import { DataTable, type DataRow } from "../../data-table";
import { closeMonth, reopenMonth, setBooksSettings, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

const monthName = (month: string) =>
  new Date(month + "T00:00:00Z").toLocaleDateString("en-US", {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });

export function ClosingForms({
  isAdmin,
  settings,
  anythingPosted,
  closed,
  years,
}: {
  isAdmin: boolean;
  settings: { books_start: string; basis: string } | null;
  anythingPosted: boolean;
  closed: { month: string; closed_at: string; closed_by_name: string; note: string }[];
  years: number[];
}) {
  const [shut, closeAction, closing] = useActionState(closeMonth, initial);
  const [open, reopenAction, reopening] = useActionState(reopenMonth, initial);
  const [saved, saveAction, saving] = useActionState(setBooksSettings, initial);
  const [reopen, setReopen] = useState<string | null>(null);

  return (
    <>
      {isAdmin && (
        <form action={saveAction} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>How the books are kept</h3>
          {saved.error && <div className="alert bad">{saved.error}</div>}
          {saved.ok && <div className="alert ok">{saved.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
            <label>
              The books open
              <input
                type="date"
                name="books_start"
                defaultValue={settings?.books_start ?? ""}
                disabled={anythingPosted}
              />
            </label>
            <label>
              Reports default to
              <select name="basis" defaultValue={settings?.basis ?? "Cash"}>
                <option value="Cash">Cash</option>
                <option value="Accrual">Accrual</option>
              </select>
            </label>
            <button className="btn" type="submit" disabled={saving}>
              Save
            </button>
          </div>
          <p className="sub">
            {anythingPosted
              ? "Entries are posted, so the start date is settled."
              : "Cash, until the CPA confirms otherwise. Either basis reads the same postings."}
          </p>
        </form>
      )}

      {isAdmin && (
        <form action={closeAction} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>Close a month</h3>
          {shut.error && <div className="alert bad">{shut.error}</div>}
          {shut.ok && <div className="alert ok">{shut.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
            <label>
              Month
              <input type="date" name="month" required />
            </label>
            <label style={{ flex: 1, minWidth: 200 }}>
              Note
              <input name="note" placeholder="Anything the CPA should know" />
            </label>
            <button className="btn" type="submit" disabled={closing}>
              Close
            </button>
          </div>
          <p className="sub">
            Any day in the month. A posting dated inside a closed month is refused, and one the CRM
            makes for itself moves to the next open month and says so.
          </p>
        </form>
      )}

      <h2 className="h2">Months that are shut</h2>
      <DataTable
        label="closed months"
        filter={false}
        columns={[
          { key: "month", label: "Month" },
          { key: "closed", label: "Closed" },
          { key: "by", label: "By" },
          { key: "note", label: "Note" },
          ...(isAdmin ? [{ key: "act", label: "", sortable: false }] : []),
        ]}
        rows={closed.map((c): DataRow => ({
          key: c.month,
          cells: {
            month: monthName(c.month),
            closed: c.closed_at.slice(0, 10),
            by: c.closed_by_name,
            note: c.note,
            ...(isAdmin
              ? {
                  act: (
                    <button
                      className="btn ghost"
                      type="button"
                      onClick={() => setReopen(reopen === c.month ? null : c.month)}
                    >
                      {reopen === c.month ? "Close" : "Reopen"}
                    </button>
                  ),
                }
              : {}),
          },
          sort: { month: c.month },
        }))}
        empty="None yet — a month is closed once it has finished and been reported on."
      />

      {isAdmin && reopen && (
        <form action={reopenAction} className="card no-print" style={{ marginTop: 16 }}>
          <h3 style={{ marginTop: 0 }}>Reopen {monthName(reopen)}</h3>
          {open.error && <div className="alert bad">{open.error}</div>}
          {open.ok && <div className="alert ok">{open.ok}</div>}
          <input type="hidden" name="month" value={reopen} />
          <label>
            Why
            <input name="reason" required autoFocus />
          </label>
          <p className="sub">This goes in the access log with your name on it.</p>
          <button className="btn" type="submit" disabled={reopening} style={{ marginTop: 8 }}>
            Reopen
          </button>
        </form>
      )}

      <h2 className="h2" style={{ marginTop: 24 }}>
        Year-end package
      </h2>
      {years.length === 0 ? (
        <p className="empty">Nothing is posted yet, so there is no year to package.</p>
      ) : (
        <p className="row2 no-print" style={{ gap: 8, flexWrap: "wrap" }}>
          {years.map((y) => (
            <a key={y} className="btn ghost" href={`/books/close/package?year=${y}`}>
              {y} package
            </a>
          ))}
        </p>
      )}
      <p className="lock">
        Every report for the year as a CSV, plus the 1099 tie-out, in one zip for the CPA.
      </p>
    </>
  );
}
