"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { fmtStamp, SERVICE_TYPES } from "@/lib/constants";
import {
  mapFolder,
  fileDocument,
  ignoreDocument,
  confirmAuthorization,
  linkNamedDocument,
  replacePlaceholder,
  type InboxState,
} from "./actions";
import { familyOf } from "@/lib/filename-rules";

/** An imported "(workbook)" authorization with no USOR number yet. */
export type Placeholder = {
  id: string;
  client_id: string;
  number: string;
  service_type: string;
  carried_used: number;
  total_hours: number | null;
};

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


type NamedChoice = {
  id: string;
  number: string;
  service_type: string;
  status: string;
  start_date: string | null;
  end_date: string | null;
};

/** What lib/file-by-name read off the document's name, and why it stopped. */
type NamedReading = {
  pattern?: string;
  label?: string;
  v_numbers?: string[];
  services?: string[];
  named?: "Authorization" | "Invoice";
  number?: string | null;
  service_type?: string | null;
  why?: string;
  choices?: NamedChoice[];
};

const namedOf = (doc: PendingRow): NamedReading =>
  ((doc.proposal ?? {}) as { filename?: NamedReading }).filename ?? {};

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

type AuthCandidate = {
  id: string;
  number: string;
  status: string;
  start_date: string | null;
  end_date: string | null;
  how: string;
};

/**
 * An authorization that arrived, and what to do with it.
 *
 * The choices are the authorizations on file for this client whose number the
 * document carries, and "go by its number". Either way the database decides
 * the rest: a number already on file gets the PDF attached rather than a
 * second authorization, and a date on file is kept.
 */
/**
 * "This is the real authorization for a placeholder."
 *
 * Offered beside confirming a new authorization when the client has an
 * imported "(workbook)" placeholder for the same service. Replacing keeps the
 * placeholder - and the hours carried on it - rather than creating a second
 * authorization that starts from zero.
 */
function ReplacePlaceholder({
  doc,
  placeholder,
  number,
  start,
  end,
}: {
  doc: PendingRow;
  placeholder: Placeholder;
  number: string;
  start: string;
  end: string;
}) {
  const [state, action, replacing] = useActionState(replacePlaceholder, initial);
  return (
    <form action={action} className="card" style={{ marginTop: 10, background: "var(--bone)" }}>
      <Message state={state} />
      <p className="sub" style={{ margin: "0 0 6px" }}>
        Or: this is the real authorization for the placeholder <b>{placeholder.number}</b> (
        {placeholder.service_type}, {Number(placeholder.carried_used)} hrs carried
        {placeholder.total_hours ? ` of ${Number(placeholder.total_hours)}` : ""}). Replacing gives the
        placeholder this number, so its hours, entries and invoices stay with it and nothing is duplicated.
      </p>
      <input type="hidden" name="document_id" value={doc.id} />
      <input type="hidden" name="placeholder_id" value={placeholder.id} />
      <div className="row2">
        <label className="field" style={{ maxWidth: 170 }}>
          Real number
          <input name="number" defaultValue={number} required />
        </label>
        <label className="field" style={{ maxWidth: 190 }}>
          Start date
          <input type="date" name="start_date" defaultValue={start} />
        </label>
        <label className="field" style={{ maxWidth: 190 }}>
          End date
          <input type="date" name="end_date" defaultValue={end} />
        </label>
      </div>
      <button className="btn" type="submit" disabled={replacing}>
        {replacing ? "…" : `Replace ${placeholder.number} with this number`}
      </button>
    </form>
  );
}

function AuthorizationProposal({
  doc,
  canBill,
  placeholders,
}: {
  doc: PendingRow;
  canBill: boolean;
  placeholders: Placeholder[];
}) {
  const [state, action, confirming] = useActionState(confirmAuthorization, initial);

  const parsed = (doc.parsed ?? {}) as Record<string, unknown>;
  const fields = (parsed.fields ?? {}) as Record<string, { value: string; source: string }>;
  const named = namedOf(doc);
  const read = (((doc.proposal ?? {}) as Record<string, unknown>).candidates ?? []) as AuthCandidate[];
  // A scan offers what its name matched instead, none of them chosen for you.
  const candidates: AuthCandidate[] = read.length
    ? read
    : (named.choices ?? []).map((c) => ({ ...c, how: `${c.service_type} on file` }));
  const v = (k: string) => fields[k]?.value ?? "";
  const serviceRead = v("serviceType") || named.service_type || "";
  const service = (SERVICE_TYPES as readonly string[]).includes(serviceRead) ? serviceRead : "";

  const [which, setWhich] = useState(read[0]?.id ?? "");
  const byNumber = which === "";

  return (
    <div style={{ marginTop: 8 }}>
      <Message state={state} />
      <p className="sub" style={{ margin: 0 }}>
        {!read.length && named.why
          ? `By its name: ${named.why}.`
          : candidates.length === 0
          ? "Read from it. No authorization on file for this client carries a number found in it."
          : candidates.length === 1
            ? `It carries ${candidates[0].number}, which is on file for this client.`
            : `It carries ${candidates.length} numbers on file for this client. Choose the one it is.`}
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

      {!canBill ? (
        <p className="lock" style={{ margin: "8px 0 0" }}>
          Admin or Billing confirms an authorization.
        </p>
      ) : (
        <form action={action} style={{ marginTop: 10 }}>
          <input type="hidden" name="document_id" value={doc.id} />

          {candidates.map((c) => (
            <label key={c.id} className="row2" style={{ gap: 6, alignItems: "center", marginBottom: 4 }}>
              <input
                type="radio"
                name="auth_id"
                value={c.id}
                checked={which === c.id}
                onChange={() => setWhich(c.id)}
                style={{ width: "auto" }}
              />
              <span>
                <b>{c.number}</b> on file · {c.start_date || "no start date"} →{" "}
                {c.end_date || "no end date"} · {c.status} <span className="lock">({c.how})</span>
              </span>
            </label>
          ))}
          <label className="row2" style={{ gap: 6, alignItems: "center", marginBottom: 8 }}>
            <input
              type="radio"
              name="auth_id"
              value=""
              checked={byNumber}
              onChange={() => setWhich("")}
              style={{ width: "auto" }}
            />
            <span>
              {candidates.length ? "None of these — go by the number below" : "Go by its number"}
            </span>
          </label>

          {byNumber && (
            <div className="row2">
              <label className="field" style={{ maxWidth: 170 }}>
                Number
                <input name="number" defaultValue={v("authNumber") || named.number || ""} required />
              </label>
              <label className="field" style={{ maxWidth: 220 }}>
                Service
                <select name="service_type" defaultValue={service}>
                  <option value="">Choose…</option>
                  {SERVICE_TYPES.map((t) => (
                    <option key={t}>{t}</option>
                  ))}
                </select>
              </label>
              <label className="field" style={{ maxWidth: 130 }}>
                Rate type
                <select name="rate_type" defaultValue={v("rateType") || "Hourly"}>
                  <option>Hourly</option>
                  <option>Flat Fee</option>
                </select>
              </label>
              <label className="field" style={{ maxWidth: 110 }}>
                Rate or fee
                <input name="rate" inputMode="decimal" defaultValue={v("rate")} />
              </label>
              <label className="field" style={{ maxWidth: 100 }}>
                Hours
                <input name="total_hours" inputMode="decimal" defaultValue={v("totalHours")} />
              </label>
            </div>
          )}

          <div className="row2">
            <label className="field" style={{ maxWidth: 190 }}>
              Start date
              <input type="date" name="start_date" defaultValue={v("startDate")} />
            </label>
            <label className="field" style={{ maxWidth: 190 }}>
              End date
              <input type="date" name="end_date" defaultValue={v("endDate")} />
            </label>
          </div>

          <p className="lock" style={{ margin: "0 0 8px" }}>
            If that number is already on file for this client, the PDF is attached to it and nothing
            new is made. Dates fill blanks only — a date already on file is kept, and a different one
            here is reported.
          </p>

          <button className="btn gold" type="submit" disabled={confirming}>
            {confirming ? "…" : byNumber ? "Confirm" : "Attach the PDF and fill blank dates"}
          </button>
        </form>
      )}

      {canBill &&
        byNumber &&
        placeholders
          .filter((p) => p.client_id === doc.client_id)
          .filter((p) => !serviceRead || familyOf(p.service_type) === familyOf(serviceRead))
          .map((p) => (
            <ReplacePlaceholder
              key={p.id}
              doc={doc}
              placeholder={p}
              number={v("authNumber") || named.number || ""}
              start={v("startDate")}
              end={v("endDate")}
            />
          ))}
    </div>
  );
}

/**
 * An invoice, by its name, that could be for more than one authorization.
 *
 * Nothing is chosen for the person: an invoice put on the wrong authorization
 * shows the wrong one as billed, and the right one as never billed at all.
 */
function NamedInvoice({ doc, canBill }: { doc: PendingRow; canBill: boolean }) {
  const [state, action, linking] = useActionState(linkNamedDocument, initial);
  const named = namedOf(doc);
  const choices = named.choices ?? [];
  const [which, setWhich] = useState("");

  return (
    <div style={{ marginTop: 8 }}>
      <Message state={state} />
      <p className="sub" style={{ margin: 0 }}>
        An invoice{named.why ? ` — ${named.why}` : ""}. Say which authorization it billed; it shows there
        as billed, and as paid once a payment for that authorization is on file.
      </p>

      {!canBill ? (
        <p className="lock" style={{ margin: "8px 0 0" }}>
          Admin or Billing puts an invoice on its authorization.
        </p>
      ) : choices.length === 0 ? (
        <p className="lock" style={{ margin: "8px 0 0" }}>
          No authorization on file for this client to put it on. Add the authorization first, or
          file it against the client below.
        </p>
      ) : (
        <form action={action} style={{ marginTop: 8 }}>
          <input type="hidden" name="document_id" value={doc.id} />
          <input type="hidden" name="category" value="Invoice" />
          {choices.map((c) => (
            <label key={c.id} className="row2" style={{ gap: 6, alignItems: "center", marginBottom: 4 }}>
              <input
                type="radio"
                name="auth_id"
                value={c.id}
                checked={which === c.id}
                onChange={() => setWhich(c.id)}
                style={{ width: "auto" }}
              />
              <span>
                <b>{c.number}</b> · {c.service_type} · {c.start_date || "no start date"} →{" "}
                {c.end_date || "no end date"} · {c.status}
              </span>
            </label>
          ))}
          <button className="btn gold" type="submit" disabled={linking || !which}>
            {linking ? "…" : "Put it on this authorization"}
          </button>
        </form>
      )}
    </div>
  );
}

function DocumentRow({
  doc,
  canBill,
  placeholders,
}: {
  doc: PendingRow;
  canBill: boolean;
  placeholders: Placeholder[];
}) {
  const [fileState, fileAction, filing] = useActionState(fileDocument, initial);
  const [ignoreState, ignoreAction] = useActionState(ignoreDocument, initial);
  const [setting, setSetting] = useState(false);

  const proposal = (doc.proposal ?? {}) as Record<string, unknown>;
  const parsed = (doc.parsed ?? {}) as Record<string, unknown>;
  const suggested = String(proposal.category ?? "Other");
  const named = namedOf(doc);

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
        <span>
          {parsed.text_source === "OCR" && (
            <span className="chip warn" style={{ marginRight: 6 }}>
              Read by OCR
              {typeof parsed.ocr_confidence === "number" ? ` · ${Math.round(parsed.ocr_confidence)}%` : ""}
            </span>
          )}
          <span className={"chip " + (doc.kind === "Unreadable" ? "bad" : "")}>{doc.kind}</span>
        </span>
      </div>

      {named.pattern && (
        <p className="lock" style={{ margin: "6px 0 0" }}>
          Its name: {named.label || named.pattern}
          {named.v_numbers?.length ? ` · ${named.v_numbers.join(", ")}` : ""}
          {named.services?.length ? ` · ${named.services.join(" / ")}` : ""}
          {!named.named && named.why ? ` — ${named.why}` : ""}
        </p>
      )}

      <Message state={fileState} />
      <Message state={ignoreState} />

      {(doc.kind === "Authorization" || named.named === "Authorization") && (
        <AuthorizationProposal doc={doc} canBill={canBill} placeholders={placeholders} />
      )}
      {named.named === "Invoice" && <NamedInvoice doc={doc} canBill={canBill} />}

      {doc.kind === "Warrant" && (
        <p className="sub" style={{ margin: "8px 0 0" }}>
          Read as a USOR warrant stub, so nothing is settled here. The agent reads it page by page on
          its next run, through the same checks as the _Warrants folder: both copies of each
          V-number agree, the page adds up, the authorization is on file. Lines that pass are paid,
          and the rest wait for review, on <Link href="/billing/warrants">Billing → Warrants</Link>.
          This entry closes by itself once every page is in.
        </p>
      )}

      {doc.kind !== "Warrant" && (
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
      )}
    </div>
  );
}

export function InboxView({
  pending,
  clients,
  canBill,
  placeholders,
}: {
  pending: PendingRow[];
  clients: { id: string; name: string }[];
  canBill: boolean;
  placeholders: Placeholder[];
}) {
  const unmatched = new Map<string, number>();
  for (const d of pending) {
    if (d.needs_a_client) {
      unmatched.set(d.folder_name, (unmatched.get(d.folder_name) ?? 0) + 1);
    }
  }

  const ready = pending.filter((d) => !d.needs_a_client);
  // Grouped by what the document is: its name, where the name settled that,
  // otherwise what its text was read as.
  const byKind = (kind: string) => ready.filter((d) => (namedOf(d).named ?? d.kind) === kind);

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

      {(["Authorization", "Invoice", "Warrant", "USOR form", "Other", "Unreadable"] as const).map((kind) => {
        const rows = byKind(kind);
        if (rows.length === 0) return null;
        return (
          <div key={kind} style={{ marginBottom: 18 }}>
            <h3 style={{ marginBottom: 6 }}>
              {kind === "USOR form"
                ? "USOR forms"
                : kind === "Other"
                  ? "Everything else"
                  : kind === "Invoice"
                    ? "Invoices"
                    : kind}
              <span className="lock" style={{ fontWeight: 400 }}> · {rows.length}</span>
            </h3>
            {kind === "Unreadable" && (
              <p className="sub" style={{ marginTop: 0 }}>
                No text in these — scans or photographs. They can still be filed against the
                client; what they say has to be read by a person.
              </p>
            )}
            {rows.map((d) => (
              <DocumentRow canBill={canBill} key={d.id} doc={d} placeholders={placeholders} />
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
