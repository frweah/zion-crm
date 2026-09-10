"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { money, fmtStamp } from "@/lib/constants";
import {
  mapFolder,
  fileDocument,
  ignoreDocument,
  matchWarrant,
  type InboxState,
} from "./actions";

const initial: InboxState = { error: null, ok: null };

export type PendingRow = {
  id: string;
  folder_name: string;
  relative_path: string;
  filename: string;
  first_seen: string;
  file_modified: string | null;
  kind: string;
  client_id: string | null;
  client_name: string | null;
  parsed: Record<string, unknown> | null;
  proposal: Record<string, unknown> | null;
  needs_a_client: boolean;
};

type Candidate = { id: string; number: string; date: string; amount: number };

const CATEGORIES = [
  "Signed USOR form",
  "Authorization",
  "Signed intake",
  "Employer verification",
  "Work schedule",
  "Invoice",
  "Other",
];

function Message({ state }: { state: InboxState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

/** A folder whose name is nobody in the CRM. Answered once, then remembered. */
function UnmatchedFolder({
  folder,
  count,
  clients,
}: {
  folder: string;
  count: number;
  clients: { id: string; name: string }[];
}) {
  const [state, action, pending] = useActionState(mapFolder, initial);

  return (
    <tr>
      <td>
        <b>{folder}</b>
        <div className="lock">
          {count} document{count === 1 ? "" : "s"} waiting
        </div>
        <Message state={state} />
      </td>
      <td>
        <form action={action} className="row2" style={{ gap: 6 }}>
          <input type="hidden" name="folder" value={folder} />
          <select name="client_id" defaultValue="" style={{ maxWidth: 240 }}>
            <option value="">Choose the client…</option>
            {clients.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "…" : "That is them"}
          </button>
        </form>
      </td>
      <td style={{ textAlign: "right" }}>
        <form action={action}>
          <input type="hidden" name="folder" value={folder} />
          <input type="hidden" name="not_a_client" value="yes" />
          <button className="btn ghost" type="submit" disabled={pending}>
            Not a client
          </button>
        </form>
      </td>
    </tr>
  );
}

function DocumentRow({ doc, today }: { doc: PendingRow; today: string }) {
  const [fileState, fileAction, filing] = useActionState(fileDocument, initial);
  const [ignoreState, ignoreAction] = useActionState(ignoreDocument, initial);
  const [warrantState, warrantAction, matching] = useActionState(matchWarrant, initial);
  const [setting, setSetting] = useState(false);

  const proposal = (doc.proposal ?? {}) as Record<string, unknown>;
  const parsed = (doc.parsed ?? {}) as Record<string, unknown>;
  const candidates = (proposal.candidates ?? []) as Candidate[];
  const suggested = String(proposal.category ?? "Other");

  const fields = (parsed.fields ?? {}) as Record<string, { value: string; source: string }>;

  return (
    <div className="card" style={{ marginBottom: 10 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <div>
          <b>{doc.filename}</b>
          <div className="lock">
            {doc.folder_name || "(loose in the top folder)"} ·{" "}
            {doc.client_name ? (
              <Link href={`/clients/${doc.client_id}`}>{doc.client_name}</Link>
            ) : (
              <span style={{ color: "var(--bad)" }}>no client yet</span>
            )}{" "}
            · seen {fmtStamp(doc.first_seen)}
          </div>
        </div>
        <span className={"chip " + (doc.kind === "Unreadable" ? "bad" : "")}>{doc.kind}</span>
      </div>

      <Message state={fileState} />
      <Message state={ignoreState} />
      <Message state={warrantState} />

      {doc.kind === "Authorization" && (
        <div style={{ marginTop: 8 }}>
          <p className="sub" style={{ margin: 0 }}>
            Read from it — nothing has been created. Check it against the PDF and create the
            authorization in Billing.
          </p>
          <table className="t" style={{ marginTop: 6 }}>
            <tbody>
              {Object.entries(fields).map(([key, f]) => (
                <tr key={key}>
                  <td style={{ width: 170 }}>{key}</td>
                  <td>
                    <b>{f.value}</b>
                    <div className="lock">{f.source}</div>
                  </td>
                </tr>
              ))}
              {Object.keys(fields).length === 0 && (
                <tr>
                  <td className="empty">Nothing could be read from it.</td>
                </tr>
              )}
            </tbody>
          </table>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            <Link href="/billing/import">Create it in Billing</Link> — the same reading, with the
            fields editable before anything is saved.
          </p>
        </div>
      )}

      {doc.kind === "Warrant" && (
        <div style={{ marginTop: 8 }}>
          <p className="sub" style={{ margin: 0 }}>
            {candidates.length === 0
              ? "No sent invoice matches any amount on it. Check it by hand."
              : `${candidates.length} sent invoice${candidates.length === 1 ? "" : "s"} match an amount on it. Pick the one it pays.`}
          </p>
          {candidates.map((c) => (
            <form action={warrantAction} key={c.id} className="row2" style={{ gap: 6, marginTop: 6 }}>
              <input type="hidden" name="document_id" value={doc.id} />
              <input type="hidden" name="invoice_id" value={c.id} />
              <input type="hidden" name="warrant" value={String(parsed.warrantNumber ?? "")} />
              <span style={{ minWidth: 220 }}>
                <b>{c.number || "(no number)"}</b>{" "}
                <span className="lock">
                  {c.date} · {money(Number(c.amount))}
                </span>
              </span>
              <label className="field" style={{ maxWidth: 160, marginBottom: 0 }}>
                Paid on
                <input type="date" name="paid_on" defaultValue={today} required />
              </label>
              <button className="btn gold" type="submit" disabled={matching}>
                {matching ? "…" : "This one"}
              </button>
            </form>
          ))}
        </div>
      )}

      <div className="row2" style={{ marginTop: 10, gap: 6 }}>
        {doc.client_id && (
          <form action={fileAction} className="row2" style={{ gap: 6 }}>
            <input type="hidden" name="document_id" value={doc.id} />
            <select name="category" defaultValue={suggested} style={{ maxWidth: 200 }}>
              {CATEGORIES.map((c) => (
                <option key={c}>{c}</option>
              ))}
            </select>
            <button className="btn" type="submit" disabled={filing}>
              {filing ? "…" : "File it against the client"}
            </button>
          </form>
        )}

        {!setting ? (
          <button className="btn ghost" type="button" onClick={() => setSetting(true)}>
            Set aside
          </button>
        ) : (
          <form action={ignoreAction} className="row2" style={{ gap: 6 }}>
            <input type="hidden" name="document_id" value={doc.id} />
            <input name="reason" placeholder="Why — a duplicate, a template…" required />
            <button className="btn" type="submit">
              Set aside
            </button>
            <button className="btn ghost" type="button" onClick={() => setSetting(false)}>
              Cancel
            </button>
          </form>
        )}
      </div>
    </div>
  );
}

export function InboxView({
  pending,
  clients,
  today,
}: {
  pending: PendingRow[];
  clients: { id: string; name: string }[];
  today: string;
}) {
  const unmatched = new Map<string, number>();
  for (const d of pending) {
    if (d.needs_a_client) {
      unmatched.set(d.folder_name, (unmatched.get(d.folder_name) ?? 0) + 1);
    }
  }

  const ready = pending.filter((d) => !d.needs_a_client);
  const byKind = (kind: string) => ready.filter((d) => d.kind === kind);

  return (
    <>
      {unmatched.size > 0 && (
        <div className="card" style={{ marginBottom: 14, padding: 0 }}>
          <div style={{ padding: "16px 16px 0" }}>
            <h3 style={{ margin: 0 }}>Folders that are not a client</h3>
            <p className="sub" style={{ margin: "4px 0 0" }}>
              {unmatched.size} folder{unmatched.size === 1 ? "" : "s"} whose name matches nobody in
              the CRM. Nothing from them is filed until somebody says whose they are — a first
              name matched to the nearest client is how one person&apos;s authorization lands on
              another&apos;s record.
            </p>
          </div>
          <table className="t">
            <tbody>
              {[...unmatched.entries()].map(([folder, count]) => (
                <UnmatchedFolder
                  key={folder}
                  folder={folder}
                  count={count}
                  clients={clients}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}

      {(["Authorization", "Warrant", "USOR form", "Other", "Unreadable"] as const).map((kind) => {
        const rows = byKind(kind);
        if (rows.length === 0) return null;
        return (
          <div key={kind} style={{ marginBottom: 18 }}>
            <h3 style={{ marginBottom: 6 }}>
              {kind === "USOR form" ? "USOR forms" : kind === "Other" ? "Everything else" : kind}
              <span className="lock" style={{ fontWeight: 400 }}> · {rows.length}</span>
            </h3>
            {kind === "Unreadable" && (
              <p className="sub" style={{ marginTop: 0 }}>
                No text in these — scans or photographs. They can still be filed against the
                client; what they say has to be read by a person.
              </p>
            )}
            {rows.map((d) => (
              <DocumentRow key={d.id} doc={d} today={today} />
            ))}
          </div>
        );
      })}

      {pending.length === 0 && (
        <div className="card">
          <p className="sub" style={{ margin: 0 }}>
            Nothing waiting. Everything the agent has sent has been filed or set aside.
          </p>
        </div>
      )}
    </>
  );
}
