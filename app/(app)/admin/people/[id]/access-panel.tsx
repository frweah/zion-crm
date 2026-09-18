"use client";

import { useActionState, useState } from "react";
import { fmtStamp } from "@/lib/constants";
import {
  AREAS,
  AREA_LABEL,
  AREA_LEVELS,
  LEVEL_LABEL,
  ROLE_AREAS,
  type Area,
  type Level,
  type Role,
} from "@/lib/roles";
import { DataTable } from "../../../data-table";
import { giveAccess, endAccess, type AccessState } from "./access-actions";

export type GrantRow = {
  id: string;
  area: Area;
  level: Level;
  reason: string;
  granted_by_name: string;
  granted_at: string;
  revoked_at: string | null;
  revoked_by_name: string;
  revoke_reason: string;
};

const initial: AccessState = { error: null, ok: null };

function EndForm({ staffId, grant }: { staffId: string; grant: GrantRow }) {
  const [state, action, pending] = useActionState(endAccess, initial);
  const id = `end-${grant.id}`;
  return (
    <details>
      <summary style={{ cursor: "pointer" }}>End it</summary>
      <form action={action} className="row2" style={{ marginTop: 6 }}>
        <input type="hidden" name="staff_id" value={staffId} />
        <input type="hidden" name="grant_id" value={grant.id} />
        <label className="field" htmlFor={id} style={{ minWidth: 200 }}>
          Why it is ending
          <input id={id} name="reason" required placeholder="Cover finished" />
        </label>
        <button className="btn danger" type="submit" disabled={pending}>
          {pending ? "…" : "End access"}
        </button>
      </form>
      {state.error && <div className="alert bad" style={{ marginTop: 6 }}>{state.error}</div>}
    </details>
  );
}

/**
 * Extra access: areas this person has been given beyond their role.
 *
 * The role stays the default. What is offered here is only what the role does
 * not already give - an area, or edit where the role gives view - so a grant
 * can only ever add. Every grant keeps who gave it, when and why; ending one
 * keeps who ended it, when and why; nothing here is ever edited or deleted.
 */
export function AccessPanel({
  staffId,
  staffName,
  role,
  grants,
  readOnly,
}: {
  staffId: string;
  staffName: string;
  role: Role;
  grants: GrantRow[];
  readOnly: boolean;
}) {
  const [state, action, pending] = useActionState(giveAccess, initial);
  const first = staffName.trim().split(/\s+/)[0] || "them";

  // What could still be given: an area their role lacks, or edit where it gives view.
  const offer = AREAS.flatMap((area) =>
    AREA_LEVELS[area]
      .filter((level) => {
        const byRole = ROLE_AREAS[role][area];
        return !(byRole && (level === "view" || byRole === "edit"));
      })
      .map((level) => ({ area, level })),
  );
  const [choice, setChoice] = useState(offer[0] ? `${offer[0].area}:${offer[0].level}` : "");
  const [area, level] = choice.split(":") as [Area, Level];

  const live = grants.filter((g) => !g.revoked_at);

  return (
    <>
      <p className="sub" style={{ marginBottom: 10 }}>
        {live.length === 0
          ? `${first} has what their role gives, and nothing more.`
          : `Beyond their role, ${first} has ${live.map((g) => `${AREA_LABEL[g.area]} (${LEVEL_LABEL[g.level]})`).join(", ")}.`}{" "}
        Access given here only ever adds to a role, is enforced by the database as well as the menu, and
        ends by itself if {first} is made inactive.
      </p>

      <div className="card" style={{ padding: 0, marginBottom: 12 }}>
        <DataTable
          label="grants"
          columns={[
            { key: "area", label: "Area" },
            { key: "level", label: "Access" },
            { key: "why", label: "Why" },
            { key: "given", label: "Given" },
            { key: "status", label: "Now" },
            { key: "action", label: "", sortable: false },
          ]}
          rows={grants.map((g) => ({
            key: g.id,
            text: [AREA_LABEL[g.area], LEVEL_LABEL[g.level], g.reason, g.granted_by_name, g.revoke_reason].join(" "),
            sort: {
              area: AREA_LABEL[g.area],
              level: g.level,
              given: g.granted_at,
              status: g.revoked_at ? `ended ${g.revoked_at}` : "current",
            },
            cells: {
              area: <b>{AREA_LABEL[g.area]}</b>,
              level: LEVEL_LABEL[g.level],
              why: g.reason,
              given: (
                <>
                  {fmtStamp(g.granted_at)}
                  <div className="lock">by {g.granted_by_name || "—"}</div>
                </>
              ),
              status: g.revoked_at ? (
                <>
                  <span className="chip">Ended</span> {fmtStamp(g.revoked_at)}
                  <div className="lock">
                    by {g.revoked_by_name || "—"}: {g.revoke_reason}
                  </div>
                </>
              ) : (
                <span className="chip ok">Current</span>
              ),
              action: !g.revoked_at && !readOnly ? <EndForm staffId={staffId} grant={g} /> : null,
            },
          }))}
          empty={`Nothing has been given to ${first} beyond their role.`}
        />
      </div>

      {!readOnly &&
        (offer.length === 0 ? (
          <p className="lock">Their role already includes every area that can be given.</p>
        ) : (
          <form action={action} className="card">
            <h3 style={{ marginTop: 0 }}>Give {first} more access</h3>
            {state.error && <div className="alert bad">{state.error}</div>}
            {state.ok && <div className="alert ok">{state.ok}</div>}
            <input type="hidden" name="staff_id" value={staffId} />
            <input type="hidden" name="area" value={area} />
            <input type="hidden" name="level" value={level} />
            <div className="row2">
              <label className="field" htmlFor="grant-choice">
                Area
                <select id="grant-choice" value={choice} onChange={(e) => setChoice(e.target.value)}>
                  {offer.map((o) => (
                    <option key={`${o.area}:${o.level}`} value={`${o.area}:${o.level}`}>
                      {AREA_LABEL[o.area]} - {LEVEL_LABEL[o.level]}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field" htmlFor="grant-reason" style={{ flex: 2 }}>
                Why
                <input id="grant-reason" name="reason" required placeholder="Covering billing while the owner is away" />
              </label>
              <button className="btn gold" type="submit" disabled={pending}>
                {pending ? "Saving…" : "Give access"}
              </button>
            </div>
            <p className="lock" style={{ margin: "8px 0 0" }}>
              {area === "insights"
                ? "Insights is Money, Referrals, Outcomes and KPIs. Capacity stays Admin's: it shows everybody's hours."
                : area === "billing"
                  ? "Billing is Authorizations, the service log, Invoices and Paid & outstanding. It does not include the rate schedule or the monthly export in Admin → System."
                  : `${AREA_LABEL[area]} opens that part of the CRM to ${first}.`}{" "}
              People and Admin → System cannot be given.
            </p>
          </form>
        ))}
    </>
  );
}
