"use client";

import { useActionState, useState } from "react";
import { DataTable, type DataRow } from "../../data-table";
import { saveVendor, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

type Vendor = {
  id: string;
  name: string;
  contact_name: string;
  email: string;
  phone: string;
  terms_days: number | null;
  gets_1099: boolean;
  w9_on_file: boolean;
  w9_received_on: string | null;
  tin_type: string | null;
  tin_last4: string | null;
  active: boolean;
  expense_account_id: string | null;
  note: string;
};

export function VendorList({
  vendors,
  accounts,
  canEdit,
}: {
  vendors: Vendor[];
  accounts: { id: string; code: string; name: string }[];
  canEdit: boolean;
}) {
  const [state, action, pending] = useActionState(saveVendor, initial);
  const [editing, setEditing] = useState<Vendor | "new" | null>(null);

  const which = editing === "new" ? null : editing;

  return (
    <>
      {canEdit && !editing && (
        <div className="no-print" style={{ marginBottom: 16 }}>
          <button className="btn gold" type="button" onClick={() => setEditing("new")}>
            Add a vendor
          </button>
          {state.ok && <span className="sub"> {state.ok}</span>}
        </div>
      )}

      {canEdit && editing && (
        <form action={action} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>{which ? which.name : "Add a vendor"}</h3>
          {state.error && <div className="alert bad">{state.error}</div>}
          {state.ok && <div className="alert ok">{state.ok}</div>}
          {which && <input type="hidden" name="id" value={which.id} />}

          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label style={{ flex: 1, minWidth: 200 }}>
              Name
              <input name="name" defaultValue={which?.name ?? ""} required />
            </label>
            <label>
              Contact
              <input name="contact_name" defaultValue={which?.contact_name ?? ""} />
            </label>
            <label>
              Email
              <input name="email" type="email" defaultValue={which?.email ?? ""} />
            </label>
            <label>
              Phone
              <input name="phone" defaultValue={which?.phone ?? ""} />
            </label>
          </div>

          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label>
              Usually posts to
              <select name="expense_account_id" defaultValue={which?.expense_account_id ?? ""}>
                <option value="">Choose on each bill</option>
                {accounts.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.code} {a.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Days to pay
              <input
                name="terms_days"
                inputMode="numeric"
                defaultValue={which?.terms_days?.toString() ?? ""}
                placeholder="30"
              />
            </label>
          </div>

          <h4 style={{ marginBottom: 4 }}>If they get a 1099</h4>
          <div className="row2" style={{ gap: 12, flexWrap: "wrap", alignItems: "center" }}>
            <label className="row2" style={{ gap: 6, alignItems: "center" }}>
              <input type="checkbox" name="gets_1099" defaultChecked={which?.gets_1099 ?? false} />
              They get a 1099
            </label>
            <label className="row2" style={{ gap: 6, alignItems: "center" }}>
              <input type="checkbox" name="w9_on_file" defaultChecked={which?.w9_on_file ?? false} />
              W-9 on file
            </label>
            <label>
              W-9 received
              <input type="date" name="w9_received_on" defaultValue={which?.w9_received_on ?? ""} />
            </label>
            <label>
              Number is an
              <select name="tin_type" defaultValue={which?.tin_type ?? ""}>
                <option value="">—</option>
                <option value="EIN">EIN</option>
                <option value="SSN">SSN</option>
              </select>
            </label>
            <label>
              Last four digits
              <input
                name="tin_last4"
                inputMode="numeric"
                maxLength={4}
                defaultValue={which?.tin_last4 ?? ""}
              />
            </label>
          </div>
          <p className="sub">The W-9 itself is a document; only these four digits are kept here.</p>

          <label>
            Note
            <input name="note" defaultValue={which?.note ?? ""} />
          </label>
          {which && (
            <label className="row2" style={{ gap: 6, alignItems: "center", marginTop: 8 }}>
              <input type="checkbox" name="active" defaultChecked={which.active} />
              Still used
            </label>
          )}

          <div className="row2" style={{ gap: 8, marginTop: 8 }}>
            <button className="btn" type="submit" disabled={pending}>
              Save
            </button>
            <button className="btn ghost" type="button" onClick={() => setEditing(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      <DataTable
        label="vendors"
        columns={[
          { key: "name", label: "Vendor" },
          { key: "contact", label: "Contact" },
          { key: "terms", label: "Days to pay", align: "right" },
          { key: "form", label: "1099" },
          { key: "standing", label: "Standing" },
          ...(canEdit ? [{ key: "act", label: "", sortable: false }] : []),
        ]}
        rows={vendors.map((v): DataRow => ({
          key: v.id,
          cells: {
            name: v.name,
            contact: [v.contact_name, v.email, v.phone].filter(Boolean).join(" · "),
            terms: v.terms_days === null ? "" : String(v.terms_days),
            form: v.gets_1099
              ? v.w9_on_file && v.tin_last4
                ? `Yes, ends ${v.tin_last4}`
                : "Yes, but no W-9 on file"
              : "No",
            standing: v.active ? "In use" : "Retired",
            ...(canEdit
              ? {
                  act: (
                    <button className="btn ghost" type="button" onClick={() => setEditing(v)}>
                      Edit
                    </button>
                  ),
                }
              : {}),
          },
          sort: { terms: v.terms_days ?? -1 },
        }))}
        empty="No vendor yet — add the landlord, the software and the accountant."
      />
    </>
  );
}
