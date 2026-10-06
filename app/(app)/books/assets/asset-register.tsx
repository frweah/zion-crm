"use client";

import { useActionState, useState } from "react";
import { money } from "@/lib/constants";
import { DataTable, type DataRow } from "../../data-table";
import { addAsset, disposeAsset, handAsset, setAssetLife, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

type Asset = {
  id: string;
  tag: string;
  name: string;
  class_label: string;
  serial: string;
  cost: number;
  written_off: number;
  book_value: number;
  acquired_on: string;
  warranty_end: string | null;
  status: string;
  held_by: string;
};

type Class = { key: string; label: string; life_months: number | null; capitalise_over: number };
type Assignment = {
  asset_id: string;
  staff_name: string;
  from_date: string;
  to_date: string | null;
  note: string;
};

export function AssetRegister({
  assets,
  classes,
  staff,
  history,
  isAdmin,
}: {
  assets: Asset[];
  classes: Class[];
  staff: { id: string; name: string }[];
  history: Assignment[];
  isAdmin: boolean;
}) {
  const [added, addAction, adding] = useActionState(addAsset, initial);
  const [handed, handAction] = useActionState(handAsset, initial);
  const [gone, disposeAction] = useActionState(disposeAsset, initial);
  const [lives, livesAction, savingLives] = useActionState(setAssetLife, initial);
  const [open, setOpen] = useState(false);
  const [chosen, setChosen] = useState<string | null>(null);

  const today = new Date().toISOString().slice(0, 10);
  const inUse = assets.filter((a) => a.status !== "Disposed");
  const worth = inUse.reduce((sum, a) => sum + Number(a.book_value), 0);

  return (
    <>
      {handed.error && <div className="alert bad">{handed.error}</div>}
      {handed.ok && <div className="alert ok">{handed.ok}</div>}
      {gone.error && <div className="alert bad">{gone.error}</div>}
      {gone.ok && <div className="alert ok">{gone.ok}</div>}

      {isAdmin && !open && (
        <div className="no-print" style={{ marginBottom: 16 }}>
          <button className="btn gold" type="button" onClick={() => setOpen(true)}>
            Add something
          </button>
          {added.ok && <span className="sub"> {added.ok}</span>}
        </div>
      )}

      {isAdmin && open && (
        <form action={addAction} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>Add something to the register</h3>
          {added.error && <div className="alert bad">{added.error}</div>}
          {added.ok && <div className="alert ok">{added.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label>
              Tag
              <input name="tag" required placeholder="ZVR-014" />
            </label>
            <label style={{ flex: 1, minWidth: 200 }}>
              What it is
              <input name="name" required placeholder="MacBook Air" />
            </label>
            <label>
              Kind
              <select name="class_key" defaultValue={classes[0]?.key ?? ""}>
                {classes.map((c) => (
                  <option key={c.key} value={c.key}>
                    {c.label}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Serial
              <input name="serial" />
            </label>
          </div>
          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label>
              Cost
              <input name="cost" inputMode="decimal" defaultValue="0" />
            </label>
            <label>
              Bought
              <input type="date" name="acquired_on" defaultValue={today} required />
            </label>
            <label>
              Warranty ends
              <input type="date" name="warranty_end" />
            </label>
            <label>
              Given to
              <select name="assigned_staff_id" defaultValue="">
                <option value="">Nobody yet</option>
                {staff.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <p className="sub">
            A cost of nothing means it was never capitalised, so it is tracked and never
            depreciated.
          </p>
          <div className="row2" style={{ gap: 8, marginTop: 8 }}>
            <button className="btn" type="submit" disabled={adding}>
              Add
            </button>
            <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      <DataTable
        label="equipment"
        columns={[
          { key: "tag", label: "Tag" },
          { key: "name", label: "What it is" },
          { key: "kind", label: "Kind" },
          { key: "held", label: "Who has it" },
          { key: "cost", label: "Cost", align: "right" },
          { key: "value", label: "Worth now", align: "right" },
          { key: "status", label: "Standing" },
          ...(isAdmin ? [{ key: "act", label: "", sortable: false }] : []),
        ]}
        rows={assets.map((a): DataRow => ({
          key: a.id,
          cells: {
            tag: a.tag,
            name: [a.name, a.serial].filter(Boolean).join(" · "),
            kind: a.class_label,
            held: a.held_by,
            cost: money(a.cost),
            value: money(a.book_value),
            status:
              a.warranty_end && a.warranty_end < today && a.status !== "Disposed"
                ? `${a.status}, out of warranty`
                : a.status,
            ...(isAdmin
              ? {
                  act:
                    a.status === "Disposed" ? (
                      ""
                    ) : (
                      <button
                        className="btn ghost"
                        type="button"
                        onClick={() => setChosen(chosen === a.id ? null : a.id)}
                      >
                        {chosen === a.id ? "Close" : "Hand on"}
                      </button>
                    ),
                }
              : {}),
          },
          sort: { cost: a.cost, value: a.book_value },
        }))}
        pageSize={60}
        empty="Nothing on the register — add the laptops and the phones."
      />

      <p className="sub">
        {inUse.length} on the register, worth {money(worth)} after depreciation.
      </p>

      {isAdmin &&
        chosen &&
        (() => {
          const asset = assets.find((a) => a.id === chosen);
          if (!asset) return null;
          const past = history.filter((h) => h.asset_id === chosen);
          return (
            <div className="card no-print" style={{ marginTop: 16 }}>
              <h3 style={{ marginTop: 0 }}>
                {asset.tag} · {asset.name}
              </h3>

              <form action={handAction} style={{ marginBottom: 12 }}>
                <input type="hidden" name="asset_id" value={asset.id} />
                <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
                  <label>
                    Hand to
                    <select name="staff_id" defaultValue="">
                      <option value="">Take it back</option>
                      {staff.map((s) => (
                        <option key={s.id} value={s.id}>
                          {s.name}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label style={{ flex: 1, minWidth: 180 }}>
                    Note
                    <input name="note" />
                  </label>
                  <button className="btn" type="submit">
                    Record it
                  </button>
                </div>
              </form>

              <form action={disposeAction}>
                <input type="hidden" name="asset_id" value={asset.id} />
                <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
                  <label>
                    Gone on
                    <input type="date" name="disposed_on" defaultValue={today} />
                  </label>
                  <label>
                    Got for it
                    <input name="proceeds" inputMode="decimal" defaultValue="0" />
                  </label>
                  <label style={{ flex: 1, minWidth: 200 }}>
                    Because
                    <input name="disposal_reason" required />
                  </label>
                  <button className="btn ghost" type="submit">
                    Dispose
                  </button>
                </div>
                <p className="sub">
                  Its cost and its depreciation come off together, and what is left is a gain or a
                  loss. It is {money(asset.book_value)} on the books now.
                </p>
              </form>

              {past.length > 0 && (
                <>
                  <h4>Who has had it</h4>
                  <ul>
                    {past.map((h, i) => (
                      <li key={i}>
                        {h.staff_name} · {h.from_date} to {h.to_date ?? "now"}
                        {h.note ? ` · ${h.note}` : ""}
                      </li>
                    ))}
                  </ul>
                </>
              )}
            </div>
          );
        })()}

      {isAdmin && (
        <form action={livesAction} className="card no-print" style={{ marginTop: 24 }}>
          <h3 style={{ marginTop: 0 }}>How long each kind lasts</h3>
          {lives.error && <div className="alert bad">{lives.error}</div>}
          {lives.ok && <div className="alert ok">{lives.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
            <label>
              Kind
              <select name="class_key" defaultValue={classes[0]?.key ?? ""}>
                {classes.map((c) => (
                  <option key={c.key} value={c.key}>
                    {c.label} · {c.life_months ?? "not depreciated"}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Months
              <input name="life_months" inputMode="numeric" placeholder="36" />
            </label>
            <label>
              Capitalise over
              <input name="capitalise_over" inputMode="decimal" placeholder="500" />
            </label>
            <button className="btn" type="submit" disabled={savingLives}>
              Save
            </button>
          </div>
          <p className="sub">
            The CPA sets these. A change applies to months not yet posted; a month already posted
            has been reported on and is left alone.
          </p>
        </form>
      )}
    </>
  );
}
