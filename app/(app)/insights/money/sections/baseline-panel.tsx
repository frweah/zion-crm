"use client";

import { useActionState } from "react";
import { money } from "@/lib/constants";
import { DataTable, type DataRow } from "../../../data-table";
import { takeBaseline, type BaselineState } from "../baseline-actions";

const initial: BaselineState = { error: null, ok: null };

export type BaselineRow = {
  id: string;
  asOf: string;
  label: string;
  authorized: number;
  earned: number;
  invoiced: number;
  received: number;
  outstanding: number;
  unbilled: number;
  clients: number;
  authorizations: number;
  documents: number;
  hours: number;
  takenAt: string;
  note: string;
  daysToSubmit: number | null;
  daysToPay: number | null;
  placements: number;
  retained4w: number;
  known4w: number;
  retained90d: number;
  known90d: number;
  byStage: Record<string, number>;
};

/**
 * A figure that has no value yet reads as unknown, not as nought.
 *
 * "0 days to submit" would be read as "same day", and "0% retention" as
 * "nobody kept their job". Neither is what an empty measure means.
 */
const orUnknown = (n: number | null, suffix: string) =>
  n === null ? "not known yet" : `${n} ${suffix}`;

const asRate = (kept: number, known: number) =>
  known === 0 ? "not known yet" : `${kept} of ${known}`;

const day = (iso: string) =>
  new Date(`${iso}T00:00:00`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });

export function BaselinePanel({
  rows,
  booksStart,
}: {
  rows: BaselineRow[];
  booksStart: string | null;
}) {
  const [state, action, pending] = useActionState(takeBaseline, initial);

  // The year before the books open is the one that needs a baseline.
  const suggested = booksStart
    ? `${Number(booksStart.slice(0, 4)) - 1}-12-31`
    : `${new Date().getFullYear()}-12-31`;

  const table: DataRow[] = rows.map((r) => ({
    key: r.id,
    text: `${r.label} ${r.asOf}`,
    sort: { asOf: r.asOf, received: r.received, outstanding: r.outstanding },
    cells: {
      asOf: (
        <>
          {day(r.asOf)}
          <span className="sub"> · {r.label}</span>
        </>
      ),
      authorized: money(r.authorized),
      received: money(r.received),
      outstanding: money(r.outstanding),
      unbilled: money(r.unbilled),
      counts: (
        <span className="sub">
          {r.clients} clients · {r.authorizations} authorizations · {r.documents} documents ·{" "}
          {r.hours} hrs
        </span>
      ),
      work: (
        <span className="sub">
          {orUnknown(r.daysToSubmit, "d to submit")} · {orUnknown(r.daysToPay, "d to pay")} ·{" "}
          {r.placements} placements · 4wk {asRate(r.retained4w, r.known4w)} · 90d{" "}
          {asRate(r.retained90d, r.known90d)}
        </span>
      ),
      stages: (
        <span className="sub">
          {Object.entries(r.byStage)
            .sort((a, b) => b[1] - a[1])
            .map(([stage, n]) => `${stage} ${n}`)
            .join(" · ") || "—"}
        </span>
      ),
    },
  }));

  return (
    <>
      <h2 className="h2">Where the practice stood</h2>
      <p className="sub">
        {booksStart
          ? `The books open ${day(booksStart)}, so nothing before it is in the ledger. A baseline is counted once and kept, and is what the year after is measured from.`
          : "A baseline is counted once and kept, and is what the year after is measured from."}
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action} className="row2" style={{ alignItems: "flex-end", gap: 8, marginTop: 10 }}>
        <label className="field" style={{ maxWidth: 190 }} htmlFor="baseline-as-of">
          As at the end of
          <input id="baseline-as-of" type="date" name="as_of" defaultValue={suggested} required />
        </label>
        <label className="field" style={{ flex: 2 }} htmlFor="baseline-label">
          What to call it
          <input id="baseline-label" name="label" placeholder="2026 baseline" />
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Counting…" : "Take it"}
        </button>
      </form>
      <p className="lock" style={{ margin: "6px 0 0" }}>
        Taken once for a day, and not edited afterwards. If the figures were wrong, take another
        for a later day and say why.
      </p>

      <div className="card" style={{ padding: 0, marginTop: 10 }}>
        <DataTable
          label="baselines"
          columns={[
            { key: "asOf", label: "As at" },
            { key: "authorized", label: "Authorized", align: "right" },
            { key: "received", label: "Received", align: "right" },
            { key: "outstanding", label: "Outstanding", align: "right" },
            { key: "unbilled", label: "Not billed", align: "right" },
            { key: "counts", label: "And" },
            { key: "work", label: "The work" },
            { key: "stages", label: "By stage" },
          ]}
          rows={table}
          empty="None taken yet. The year before the books open is the one that needs one."
        />
      </div>
    </>
  );
}
