"use client";

import { useState, useMemo, useActionState } from "react";
import Link from "next/link";
import { addClient, type ClientFormState } from "./actions";

export type ClientRow = {
  id: string;
  name: string;
  client_no: number | null;
  stage: string;
  status: string;
  agency_id: string;
  referring_office: string;
  import_review: string;
  counselor_name: string;
  assigned_name: string;
};

type Option = { id: string; name: string };

const initial: ClientFormState = { error: null, ok: null };

const FUNDING = ["Utah VR", "HCBS Medicaid", "Private Pay", "Other"];

export function ClientsView({
  clients,
  counselors,
  staff,
  offices,
  canEdit,
  roleNote,
}: {
  clients: ClientRow[];
  counselors: Option[];
  staff: Option[];
  offices: string[];
  canEdit: boolean;
  roleNote: string;
}) {
  const [adding, setAdding] = useState(false);
  const [q, setQ] = useState("");
  const [showClosed, setShowClosed] = useState(false);
  const [state, action, pending] = useActionState(addClient, initial);

  const closedCount = clients.filter((c) => c.status === "Closed").length;

  const list = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return clients
      .filter((c) => showClosed || c.status !== "Closed")
      .filter((c) => {
        if (!needle) return true;
        return (
          c.name.toLowerCase().includes(needle) ||
          c.agency_id.toLowerCase().includes(needle) ||
          String(c.client_no ?? "").includes(needle) ||
          c.counselor_name.toLowerCase().includes(needle)
        );
      })
      .sort((a, b) => a.name.localeCompare(b.name));
  }, [clients, q, showClosed]);

  const flagged = list.filter((c) => c.import_review).length;

  return (
    <>
      <div className="row2" style={{ justifyContent: "space-between", marginBottom: 6 }}>
        <div>
          <h1 className="h1">Clients</h1>
          <p className="sub" style={{ margin: 0 }}>
            {roleNote}
          </p>
        </div>
        {canEdit && (
          <button className="btn gold" onClick={() => setAdding(!adding)}>
            {adding ? "Cancel" : "Add client"}
          </button>
        )}
      </div>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {adding && canEdit && (
        <div className="card" style={{ margin: "14px 0" }}>
          <form action={action}>
            <div className="row2">
              <label className="field">
                Full name
                <input name="name" required />
              </label>
              <label className="field">
                Agency client ID
                <input name="agency_id" />
              </label>
              <label className="field">
                Funding source
                <select name="funding_source" defaultValue="Utah VR">
                  {FUNDING.map((x) => (
                    <option key={x}>{x}</option>
                  ))}
                </select>
              </label>
            </div>

            <div className="row2" style={{ marginTop: 10 }}>
              <label className="field">
                Counselor
                <select name="counselor_id" defaultValue="">
                  <option value="">—</option>
                  {counselors.map((k) => (
                    <option key={k.id} value={k.id}>
                      {k.name}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                Counselor phone / fax
                <input name="counselor_contact" />
              </label>
              <label className="field">
                Referring office
                <select name="referring_office" defaultValue="">
                  <option value="">—</option>
                  {offices.map((o) => (
                    <option key={o}>{o}</option>
                  ))}
                </select>
              </label>
            </div>

            <div className="row2" style={{ marginTop: 10 }}>
              <label className="field">
                Caseload
                <input name="caseload" />
              </label>
              <label className="field">
                Unit
                <input name="unit" />
              </label>
              <label className="field">
                Assigned staff
                <select name="assigned_staff_id" defaultValue="">
                  <option value="">—</option>
                  {staff.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field" style={{ maxWidth: 220 }}>
                Date of birth
                <input name="dob" type="date" />
              </label>
            </div>

            <p className="lock" style={{ margin: "10px 0 0" }}>
              Date of birth is a restricted field — visible only to Admin, Intake &amp; Reports,
              and the assigned staff member.
            </p>

            <div className="row2" style={{ marginTop: 12 }}>
              <button className="btn" type="submit" disabled={pending}>
                {pending ? "Saving…" : "Save client"}
              </button>
              <span className="lock">
                Saving starts the client at Referral and raises the intake task for Job Search.
              </span>
            </div>
          </form>
        </div>
      )}

      <div className="row2" style={{ margin: "10px 0 14px" }}>
        <input
          placeholder="Search by name, client #, agency ID, or counselor"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          style={{ maxWidth: 340 }}
        />
        <label style={{ fontSize: 12 }}>
          <input
            type="checkbox"
            style={{ width: "auto", marginRight: 6 }}
            checked={showClosed}
            onChange={(e) => setShowClosed(e.target.checked)}
          />
          Show closed ({closedCount})
        </label>
        <span className="lock">
          {list.length} shown{flagged > 0 ? ` · ${flagged} flagged for review` : ""}
        </span>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table className="t">
          <thead>
            <tr>
              <th>Client</th>
              <th>#</th>
              <th>Stage</th>
              <th>Office</th>
              <th>Counselor</th>
              <th>Assigned</th>
            </tr>
          </thead>
          <tbody>
            {list.length === 0 && (
              <tr>
                <td colSpan={6} className="empty">
                  {clients.length === 0
                    ? "No clients yet. They arrive with the data migration."
                    : "No clients match."}
                </td>
              </tr>
            )}
            {list.map((c) => (
              <tr key={c.id} className="row">
                <td>
                  <Link href={`/clients/${c.id}`} style={{ color: "inherit", fontWeight: 600 }}>
                    {c.name}
                  </Link>
                  {c.status !== "Active" && (
                    <span className="chip" style={{ marginLeft: 6 }}>
                      {c.status}
                    </span>
                  )}
                  {c.import_review && (
                    <span className="chip warn" style={{ marginLeft: 6 }} title={c.import_review}>
                      review
                    </span>
                  )}
                </td>
                <td>{c.client_no ?? ""}</td>
                <td>
                  <span className="chip gold">{c.stage}</span>
                </td>
                <td>{c.referring_office}</td>
                <td>{c.counselor_name}</td>
                <td>{c.assigned_name || "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
