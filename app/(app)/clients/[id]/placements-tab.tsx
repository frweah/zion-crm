"use client";

import { useActionState } from "react";
import { addPlacement, updatePlacement, type DetailState } from "./actions";
import { today, daysBetween } from "@/lib/constants";

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
};

function retention(p: PlacementRow) {
  if (p.check90) return { label: "90-day retained", cls: "chip ok" };
  if (!p.start_date) return { label: "no start date", cls: "chip" };
  const days = daysBetween(p.start_date, today());
  return { label: `${days} days in`, cls: days >= 90 ? "chip warn" : "chip" };
}

function PlacementCard({
  clientId,
  placement,
  canEdit,
  canBill,
}: {
  clientId: string;
  placement: PlacementRow;
  canEdit: boolean;
  canBill: boolean;
}) {
  const [state, action, pending] = useActionState(updatePlacement, initial);
  const badge = retention(placement);

  return (
    <div className="card" style={{ marginBottom: 10 }}>
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
    </div>
  );
}

export function PlacementsTab({
  clientId,
  placements,
  canEdit,
  canBill,
}: {
  clientId: string;
  placements: PlacementRow[];
  canEdit: boolean;
  canBill: boolean;
}) {
  const [state, action, pending] = useActionState(addPlacement, initial);

  return (
    <>
      {placements.length === 0 && <div className="empty">No placements yet.</div>}

      {placements.map((p) => (
        <PlacementCard
          key={p.id}
          clientId={clientId}
          placement={p}
          canEdit={canEdit}
          canBill={canBill}
        />
      ))}

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
