"use client";

import { useActionState } from "react";
import { addPlacement, updatePlacement, type DetailState } from "./actions";
import { today, daysBetween, money } from "@/lib/constants";

const initial: DetailState = { error: null, ok: null };

export type PlacementRow = {
  id: string;
  employer: string;
  title: string;
  start_date: string | null;
  wage: number | null;
  hours_week: number | null;
  check30: string | null;
  check60: string | null;
  check90: string | null;
  jp_submitted: string | null;
  jp_paid: string | null;
  shifts_worked: number | null;
  fifth_shift_on: string | null;
  stability_on: string | null;
  stability_basis: string | null;
  employer_benefits: boolean | null;
  stem_occupation: boolean | null;
  rural_client: boolean | null;
};

/** One indicator, as the database works it out (0112). */
export type HqiRow = {
  key: string;
  label: string;
  met: boolean | null;
  detail: string;
  amount: number;
};

const yesNo = (v: boolean | null) => (v === null || v === undefined ? "" : v ? "yes" : "no");

function retention(p: PlacementRow) {
  if (p.check90) return { label: "90-day retained", cls: "chip ok" };
  if (!p.start_date) return { label: "no start date", cls: "chip" };
  const days = daysBetween(p.start_date, today());
  return { label: `${days} days in`, cls: days >= 90 ? "chip warn" : "chip" };
}

function PlacementItem({
  clientId,
  placement,
  canEdit,
  canBill,
  indicators,
}: {
  clientId: string;
  placement: PlacementRow;
  canEdit: boolean;
  canBill: boolean;
  indicators: HqiRow[];
}) {
  const [state, action, pending] = useActionState(updatePlacement, initial);
  const badge = retention(placement);

  return (
    <div className="list-item">
      <div className="row2" style={{ justifyContent: "space-between" }}>
        <b>
          {placement.employer || "(employer not recorded)"}
          {placement.title ? ` — ${placement.title}` : ""}
        </b>
        <span className={badge.cls}>{badge.label}</span>
      </div>

      {state.error && <div className="alert bad" style={{ marginTop: 10 }}>{state.error}</div>}
      {state.ok && <div className="alert ok" style={{ marginTop: 10 }}>{state.ok}</div>}

      <form action={action}>
        <input type="hidden" name="id" value={clientId} />
        <input type="hidden" name="placement_id" value={placement.id} />

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field">
            Employer
            <input name="employer" defaultValue={placement.employer} disabled={!canEdit} />
          </label>
          <label className="field">
            Job title
            <input name="title" defaultValue={placement.title} disabled={!canEdit} />
          </label>
          <label className="field" style={{ maxWidth: 160 }}>
            Start date
            <input
              name="start_date"
              type="date"
              max={today()}
              defaultValue={placement.start_date ?? ""}
              disabled={!canEdit}
            />
          </label>
          <label className="field" style={{ maxWidth: 110 }}>
            $/hr
            <input
              name="wage"
              type="number"
              step="0.25"
              defaultValue={placement.wage ?? ""}
              disabled={!canEdit}
            />
          </label>
          <label className="field" style={{ maxWidth: 110 }}>
            Hrs/wk
            <input
              name="hours_week"
              type="number"
              defaultValue={placement.hours_week ?? ""}
              disabled={!canEdit}
            />
          </label>
        </div>

        {/*
          The two moments the CRP billing pathway turns on (owner, 20 Sept
          2026). Neither is computed: a shift is a shift somebody worked, and
          stability is a judgement about a person. The CRM carries them once
          somebody knows them, and stops the claim being forgotten.
        */}
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" style={{ maxWidth: 120 }}>
            Shifts worked
            <input
              name="shifts_worked"
              type="number"
              min="0"
              max="500"
              defaultValue={placement.shifts_worked ?? 0}
              disabled={!canEdit}
            />
            <span className="lock">A split shift counts as one</span>
          </label>
          <label className="field" style={{ maxWidth: 160 }}>
            Fifth shift on
            <input
              name="fifth_shift_on"
              type="date"
              max={today()}
              defaultValue={placement.fifth_shift_on ?? ""}
              disabled={!canEdit}
            />
            <span className="lock">Job Placement bills from here, on USOR 92</span>
          </label>
          <label className="field" style={{ maxWidth: 160 }}>
            Stable since
            <input
              name="stability_on"
              type="date"
              max={today()}
              defaultValue={placement.stability_on ?? ""}
              disabled={!canEdit}
            />
            <span className="lock">What an HQI invoice is dated</span>
          </label>
          <label className="field" style={{ maxWidth: 150 }}>
            Which rule
            <select name="stability_basis" defaultValue={placement.stability_basis ?? ""} disabled={!canEdit}>
              <option value="">Not decided</option>
              <option value="SJBT">SJBT — 30 days CIE</option>
              <option value="SE">SE — 80/20 or 24 months</option>
            </select>
          </label>
        </div>

        {/*
          The three High Quality Indicators nothing in the CRM can answer: an
          employer's benefits, what O*NET calls the occupation, and where the
          client lives. Three states, not two - "nobody has looked" is not
          "no", and the difference is $560 an indicator.
        */}
        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" style={{ maxWidth: 190 }}>
            Employer pays health benefits
            <select name="employer_benefits" defaultValue={yesNo(placement.employer_benefits)} disabled={!canEdit}>
              <option value="">Not answered</option>
              <option value="yes">Yes</option>
              <option value="no">No</option>
            </select>
          </label>
          <label className="field" style={{ maxWidth: 190 }}>
            STEM occupation on O*NET
            <select name="stem_occupation" defaultValue={yesNo(placement.stem_occupation)} disabled={!canEdit}>
              <option value="">Not answered</option>
              <option value="yes">Yes</option>
              <option value="no">No</option>
            </select>
          </label>
          <label className="field" style={{ maxWidth: 190 }}>
            Client lives rurally
            <select name="rural_client" defaultValue={yesNo(placement.rural_client)} disabled={!canEdit}>
              <option value="">Not answered</option>
              <option value="yes">Yes</option>
              <option value="no">No</option>
            </select>
          </label>
        </div>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" style={{ maxWidth: 150 }}>
            30-day check
            <input
              name="check30"
              type="date"
              max={today()}
              defaultValue={placement.check30 ?? ""}
              disabled={!canEdit}
            />
          </label>
          <label className="field" style={{ maxWidth: 150 }}>
            60-day check
            <input
              name="check60"
              type="date"
              max={today()}
              defaultValue={placement.check60 ?? ""}
              disabled={!canEdit}
            />
          </label>
          <label className="field" style={{ maxWidth: 150 }}>
            90-day check
            <input
              name="check90"
              type="date"
              max={today()}
              defaultValue={placement.check90 ?? ""}
              disabled={!canEdit}
            />
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Fee submitted
            <input
              name="jp_submitted"
              type="date"
              max={today()}
              defaultValue={placement.jp_submitted ?? ""}
              disabled={!canBill}
            />
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Fee paid
            <input
              name="jp_paid"
              type="date"
              max={today()}
              defaultValue={placement.jp_paid ?? ""}
              disabled={!canBill}
            />
          </label>
        </div>

        {(canEdit || canBill) && (
          <div style={{ marginTop: 12 }}>
            <button className="btn" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Save placement"}
            </button>
            {!canBill && <span className="lock" style={{ marginLeft: 10 }}>Fee dates are Billing&apos;s.</span>}
            {!canEdit && <span className="lock" style={{ marginLeft: 10 }}>You can edit the fee dates only.</span>}
          </div>
        )}
      </form>

      <Indicators rows={indicators} />
    </div>
  );
}


/**
 * The High Quality Indicators for one placement.
 *
 * Six at $560 each, from the fee schedule USOR publishes. Only the ones
 * answered "yes" are counted; one nobody has looked at is shown as such and
 * left out of the total, because a total that treats "we have not checked"
 * as "no" is a total that quietly loses $560 a time.
 */
function Indicators({ rows }: { rows: HqiRow[] }) {
  if (rows.length === 0) return null;
  const met = rows.filter((r) => r.met === true);
  const unanswered = rows.filter((r) => r.met === null);
  const total = met.reduce((sum, r) => sum + Number(r.amount), 0);

  return (
    <details className="hqi">
      <summary>
        High Quality Indicators — <b>{money(total)}</b> from {met.length} of {rows.length}{" "}
        {unanswered.length > 0 && <span className="chip warn">{unanswered.length} unanswered</span>}
      </summary>
      <ul>
        {rows.map((r) => (
          <li key={r.key} className={r.met === true ? "on" : r.met === null ? "unknown" : undefined}>
            <span className="hqi-mark" aria-hidden="true">
              {r.met === true ? "\u2713" : r.met === null ? "?" : "\u00d7"}
            </span>
            <span>
              <b>{r.label}</b>
              <span className="lock"> {r.detail}</span>
            </span>
            <span className="hqi-amount">{r.met === true ? money(Number(r.amount)) : "—"}</span>
          </li>
        ))}
      </ul>
      <p className="lock">
        Billed against the HQI authorization the counselor raises at stability, dated the stability date. The
        authorization is still what decides the amount — this is what the schedule says it should come to.
      </p>
    </details>
  );
}

export function PlacementsTab({
  clientId,
  placements,
  canEdit,
  canBill,
  indicators,
}: {
  clientId: string;
  placements: PlacementRow[];
  canEdit: boolean;
  canBill: boolean;
  /** The six High Quality Indicators per placement, worked out by 0112. */
  indicators: Record<string, HqiRow[]>;
}) {
  const [state, action, pending] = useActionState(addPlacement, initial);

  return (
    <>
      {placements.length === 0 && <div className="empty">No placements yet.</div>}

      {/*
        One container, a placement to each item: each carries its own form, so
        they are a list rather than a table, and not a stack of separate cards.
        The form for a new placement is a single panel, so it stays a card.
      */}
      {placements.length > 0 && (
        <div className="list" style={{ marginBottom: 14 }}>
          {placements.map((p) => (
            <PlacementItem
              key={p.id}
              clientId={clientId}
              placement={p}
              canEdit={canEdit}
              canBill={canBill}
              indicators={indicators[p.id] ?? []}
            />
          ))}
        </div>
      )}

      {canEdit && (
        <div className="card">
          <h3>Record a new placement</h3>
          {state.error && <div className="alert bad">{state.error}</div>}
          {state.ok && <div className="alert ok">{state.ok}</div>}
          <form action={action} className="row2">
            <input type="hidden" name="id" value={clientId} />
            <label className="field">
              Employer
              <input name="employer" required />
            </label>
            <label className="field">
              Job title
              <input name="title" />
            </label>
            <label className="field" style={{ maxWidth: 160 }}>
              Start
              <input name="start_date" type="date" max={today()} defaultValue={today()} />
            </label>
            <label className="field" style={{ maxWidth: 110 }}>
              $/hr
              <input name="wage" type="number" step="0.25" />
            </label>
            <label className="field" style={{ maxWidth: 110 }}>
              Hrs/wk
              <input name="hours_week" type="number" />
            </label>
            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Adding…" : "Add placement"}
            </button>
          </form>
          <p className="lock" style={{ margin: "10px 0 0" }}>
            90-day retention is what USOR measures — record the job the same week it starts.
          </p>
        </div>
      )}
    </>
  );
}
