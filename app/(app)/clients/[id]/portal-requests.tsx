"use client";

import { useActionState, useState } from "react";
import { fmtStamp } from "@/lib/constants";
import { askForDocument, withdrawRequest, reviewUpload, type RequestState } from "./request-actions";
import { OpenFile } from "./authorization-files";

export type PortalRequestRow = {
  id: string;
  item: string;
  label: string;
  note: string;
  due: string | null;
  status: string;
  return_reason: string;
  requested_by_name: string;
  created_at: string;
  answered_at: string | null;
  storage_path: string | null;
  filename: string | null;
};

const ITEMS = ["Resume", "Photo ID", "Social Security card", "Signed form", "Other"] as const;
const initial: RequestState = { error: null, ok: null };

const STATUS: Record<string, string> = {
  Open: "Waiting on the client",
  Returned: "Sent back, waiting on the client",
  Answered: "Uploaded, needs review",
  Accepted: "Accepted",
  Cancelled: "Withdrawn",
};

/**
 * Documents asked for through the portal, from the client's record: ask for
 * one, see what is waiting, review what came in.
 */
export function PortalRequests({
  clientId,
  requests,
  canManage,
  hasAccess,
}: {
  clientId: string;
  requests: PortalRequestRow[];
  canManage: boolean;
  hasAccess: boolean;
}) {
  const [askState, askAction, asking] = useActionState(askForDocument, initial);
  const [wState, wAction, withdrawing] = useActionState(withdrawRequest, initial);
  const [rState, rAction, reviewing] = useActionState(reviewUpload, initial);
  const [item, setItem] = useState<string>("Resume");
  const [returning, setReturning] = useState<string | null>(null);
  const error = askState.error ?? wState.error ?? rState.error;
  const ok = askState.ok ?? wState.ok ?? rState.ok;

  return (
    <div className="card" style={{ marginTop: 14 }} id="portal-requests">
      <h2 className="h2" style={{ marginTop: 0 }}>
        Document requests
      </h2>
      {error && <div className="alert bad">{error}</div>}
      {ok && <div className="alert good">{ok}</div>}

      {canManage && hasAccess && (
        <form action={askAction} className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
          <input type="hidden" name="client_id" value={clientId} />
          <label className="field" style={{ margin: 0 }}>
            <span>Ask for</span>
            <select name="item" value={item} onChange={(e) => setItem(e.target.value)}>
              {ITEMS.map((i) => (
                <option key={i}>{i}</option>
              ))}
            </select>
          </label>
          {item === "Other" && (
            <label className="field" style={{ margin: 0 }}>
              <span>What</span>
              <input name="label" required maxLength={80} placeholder="Pay stub" />
            </label>
          )}
          <label className="field" style={{ margin: 0, flex: 1, minWidth: 200 }}>
            <span>Note to the client</span>
            <input name="note" maxLength={500} placeholder="Optional" />
          </label>
          <label className="field" style={{ margin: 0 }}>
            <span>Due</span>
            <input name="due" type="date" />
          </label>
          <button className="btn gold" type="submit" disabled={asking}>
            {asking ? "Asking…" : "Ask in portal"}
          </button>
        </form>
      )}
      {canManage && !hasAccess && <p className="lock">Give portal access first to ask for documents here.</p>}

      {requests.length === 0 ? (
        <p className="lock" style={{ marginBottom: 0 }}>
          Nothing asked for through the portal yet.
        </p>
      ) : (
        <table className="table" data-layout="why" style={{ marginTop: 12 }}>
          <thead>
            <tr>
              <th>Document</th>
              <th>Status</th>
              <th>Asked</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {requests.map((r) => (
              <tr key={r.id}>
                <td>
                  <b>{r.item === "Other" ? r.label : r.item}</b>
                  {r.note && <div className="lock">{r.note}</div>}
                  {r.due && <div className="lock">Due {r.due}</div>}
                </td>
                <td>
                  {STATUS[r.status] ?? r.status}
                  {r.status === "Returned" && r.return_reason && <div className="lock">{r.return_reason}</div>}
                  {r.answered_at && r.status !== "Open" && (
                    <div className="lock">Uploaded {fmtStamp(r.answered_at)}</div>
                  )}
                </td>
                <td className="lock">
                  {fmtStamp(r.created_at)}
                  {r.requested_by_name && ` · ${r.requested_by_name}`}
                </td>
                <td>
                  <div className="row2" style={{ gap: 6, flexWrap: "wrap" }}>
                    {r.storage_path && r.status !== "Open" && r.status !== "Returned" && (
                      <OpenFile file={{ storage_path: r.storage_path }} />
                    )}
                    {canManage && r.status === "Answered" && returning !== r.id && (
                      <>
                        <form action={rAction}>
                          <input type="hidden" name="client_id" value={clientId} />
                          <input type="hidden" name="request_id" value={r.id} />
                          <input type="hidden" name="decision" value="accept" />
                          <button className="btn" type="submit" disabled={reviewing}>
                            Accept
                          </button>
                        </form>
                        <button className="btn ghost" type="button" onClick={() => setReturning(r.id)}>
                          Send back
                        </button>
                      </>
                    )}
                    {canManage && (r.status === "Open" || r.status === "Returned") && (
                      <form action={wAction}>
                        <input type="hidden" name="client_id" value={clientId} />
                        <input type="hidden" name="request_id" value={r.id} />
                        <button className="btn ghost" type="submit" disabled={withdrawing}>
                          Withdraw
                        </button>
                      </form>
                    )}
                  </div>
                  {returning === r.id && (
                    <form action={rAction} style={{ marginTop: 6 }}>
                      <input type="hidden" name="client_id" value={clientId} />
                      <input type="hidden" name="request_id" value={r.id} />
                      <input type="hidden" name="decision" value="return" />
                      <label className="field" style={{ margin: 0 }}>
                        <span>What the client should fix</span>
                        <input name="reason" required maxLength={300} placeholder="The bottom of the page is cut off" />
                      </label>
                      <div className="row2" style={{ gap: 6, marginTop: 6 }}>
                        <button className="btn danger" type="submit" disabled={reviewing}>
                          Send back
                        </button>
                        <button className="btn ghost" type="button" onClick={() => setReturning(null)}>
                          Keep it
                        </button>
                      </div>
                    </form>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
