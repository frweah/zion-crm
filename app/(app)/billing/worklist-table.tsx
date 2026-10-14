"use client";

import { useActionState } from "react";
import { DataTable, type DataColumn, type DataRow } from "../data-table";
import {
  bulkMarkPaid,
  bulkCloseAuthorizations,
  EMPTY_BATCH,
  type BatchState,
} from "./authorizations/actions";

/**
 * The working list, with rows that can be chosen (owner, 14 Oct 2026).
 *
 * "Many items in the queue were paid long ago; this is how they get cleared."
 *
 * A client component only because the choosing is: DataTable takes a function
 * to draw the bar above the chosen rows, and a function cannot be handed from
 * a server component to a client one. The list itself is still built on the
 * server and the cells arrive already rendered.
 *
 * Billing and Admin see the checkboxes. Everybody else sees the same list
 * without them, rather than a column of controls that refuse.
 */
export function WorklistTable({
  columns,
  rows,
  empty,
  canClear,
  today,
}: {
  columns: DataColumn[];
  rows: DataRow[];
  empty: string;
  canClear: boolean;
  today: string;
}) {
  return (
    <DataTable
      label="authorizations being worked"
      sortBy
      pageSize={50}
      columns={columns}
      rows={rows}
      empty={empty}
      choose={
        canClear
          ? (chosen, clear) => <BulkClear chosen={chosen} clear={clear} today={today} />
          : undefined
      }
    />
  );
}

/**
 * Mark paid with one date, or close with one reason.
 *
 * Two forms rather than one with a mode, because they ask for different
 * things and a single control that changes what the field means is how
 * somebody closes ten authorizations they meant to pay.
 *
 * Neither clears the choice on its own. A batch where some rows were left
 * alone is the normal case here - six of the practice's open authorizations
 * come to nothing - so the rows stay chosen, the ones that did not go through
 * are listed with what stopped them, and letting go is a button.
 */
function BulkClear({
  chosen,
  clear,
  today,
}: {
  chosen: string[];
  clear: () => void;
  today: string;
}) {
  const [paid, payAction, paying] = useActionState(bulkMarkPaid, EMPTY_BATCH);
  const [closed, closeAction, closing] = useActionState(bulkCloseAuthorizations, EMPTY_BATCH);
  const busy = paying || closing;
  const many = chosen.length !== 1;

  return (
    <>
      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(260px, 1fr))" }}>
        <form action={payAction} className="card">
          {chosen.map((id) => (
            <input key={id} type="hidden" name="auth_ids" value={id} />
          ))}
          <h3 className="h2">Mark paid</h3>
          <p className="lock">
            One received date for {many ? `all ${chosen.length}` : "it"}. Each takes its own amount
            from its own record.
          </p>
          <label className="field">
            <span>Date received</span>
            <input type="date" name="received" defaultValue={today} required />
          </label>
          <button className="btn gold" disabled={busy}>
            {paying ? "Recording…" : `Mark ${chosen.length} paid`}
          </button>
        </form>

        <form action={closeAction} className="card">
          {chosen.map((id) => (
            <input key={id} type="hidden" name="auth_ids" value={id} />
          ))}
          <h3 className="h2">Close</h3>
          <p className="lock">
            One reason, kept on every record. For work that never happened, or months with nothing
            in them.
          </p>
          <label className="field">
            <span>Why</span>
            <input name="reason" required placeholder="Never billed; confirmed with the counselor" />
          </label>
          <button className="btn" disabled={busy}>
            {closing ? "Closing…" : `Close ${chosen.length}`}
          </button>
        </form>
      </div>

      <Outcome state={paid} clear={clear} />
      <Outcome state={closed} clear={clear} />
    </>
  );
}

/** What happened, per row, for the rows that did not go through. */
function Outcome({ state, clear }: { state: BatchState; clear: () => void }) {
  if (state.error) return <p className="alert bad">{state.error}</p>;
  if (!state.ok) return null;
  return (
    <>
      <p className={state.rows.length ? "alert" : "alert ok"}>
        {state.ok}{" "}
        {state.rows.length === 0 ? (
          <button type="button" className="btn ghost" onClick={clear}>
            Choose none
          </button>
        ) : null}
      </p>
      {state.rows.length > 0 && (
        <table
          className="t"
          data-layout="the rows that were left alone: the authorization, whose it is, and what stopped it"
        >
          <tbody>
            {state.rows.map((r, n) => (
              <tr key={n}>
                <td>{r.auth_number}</td>
                <td className="lock">{r.client_name}</td>
                <td className="lock">{r.detail}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
