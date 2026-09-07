"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import {
  generate1099Run,
  record1099Delivery,
  recordRunFiled,
  downloadCopyB,
  downloadFilingCsv,
  type ContractorState,
} from "./actions";

const initial: ContractorState = { error: null, ok: null };
const initialFile: ContractorState & { filename?: string; contentBase64?: string } = {
  error: null,
  ok: null,
};

const usd = (n: number) => n.toLocaleString("en-US", { style: "currency", currency: "USD" });

/**
 * Hands a generated file to the browser.
 *
 * Neither the Copy B nor the filing files are written to storage. A copy of
 * somebody's tax document, or a spreadsheet of taxpayer numbers, should exist
 * for as long as it takes to save it and no longer — so each is built on
 * demand from the run's own snapshot and passed straight through.
 */
function useFileDownload(state: { filename?: string; contentBase64?: string }) {
  const done = useRef<string | null>(null);

  useEffect(() => {
    if (!state.filename || !state.contentBase64) return;
    const key = state.filename + state.contentBase64.length;
    if (done.current === key) return;
    done.current = key;

    const binary = atob(state.contentBase64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

    const url = URL.createObjectURL(new Blob([bytes]));
    const a = document.createElement("a");
    a.href = url;
    a.download = state.filename;
    a.click();
    URL.revokeObjectURL(url);
  }, [state.filename, state.contentBase64]);
}

export function GenerateRun({ year, canRun, why }: { year: number; canRun: boolean; why: string }) {
  const [state, action, pending] = useActionState(generate1099Run, initial);

  return (
    <div className="card">
      <h3>Generate the {year} run</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        A run is a snapshot. Once it exists, the names, addresses and amounts on it are what was
        filed, and later edits to a profile do not rewrite it.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      {!canRun && <div className="alert warn">{why}</div>}

      <form action={action}>
        <input type="hidden" name="year" value={year} />
        <button className="btn gold" type="submit" disabled={pending || !canRun}>
          {pending ? "Building…" : `Build the ${year} run`}
        </button>
      </form>
      <p className="lock" style={{ marginBottom: 0 }}>
        The run refuses to build if anyone over the threshold is missing a taxpayer number, a W-9
        or an address. It will say who.
      </p>
    </div>
  );
}

export function CopyBButton({ recipientId, name }: { recipientId: string; name: string }) {
  const [state, action, pending] = useActionState(downloadCopyB, initialFile);
  useFileDownload(state);

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="recipient_id" value={recipientId} />
      <button className="btn ghost" type="submit" disabled={pending} title={`Copy B for ${name}`}>
        {pending ? "…" : "Copy B"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

export function FilingCsvButtons({ runId }: { runId: string }) {
  const [state, action, pending] = useActionState(downloadFilingCsv, initialFile);
  useFileDownload(state);

  return (
    <>
      {state.error && <div className="alert bad">{state.error}</div>}
      <form action={action} style={{ display: "inline-flex", gap: 8 }}>
        <input type="hidden" name="run_id" value={runId} />
        <button className="btn" type="submit" name="kind" value="generic" disabled={pending}>
          {pending ? "…" : "Filing CSV"}
        </button>
        <button className="btn" type="submit" name="kind" value="iris" disabled={pending}>
          {pending ? "…" : "IRIS CSV"}
        </button>
      </form>
    </>
  );
}

export function DeliveryForm({
  recipientId,
  consent,
  deliveredOn,
  method,
  defaultDate,
}: {
  recipientId: string;
  consent: boolean;
  deliveredOn: string | null;
  method: string | null;
  defaultDate: string;
}) {
  const [state, action, pending] = useActionState(record1099Delivery, initial);

  if (deliveredOn) {
    return (
      <span className="chip ok">
        {method} · {deliveredOn}
      </span>
    );
  }

  return (
    <form action={action} style={{ display: "flex", gap: 6, alignItems: "center" }}>
      <input type="hidden" name="recipient_id" value={recipientId} />
      <select name="method" defaultValue={consent ? "Email" : "Post"} style={{ fontSize: 12 }}>
        <option value="Secure download">Secure download</option>
        <option value="Email">Email</option>
        <option value="Post">Post</option>
        <option value="In person">In person</option>
      </select>
      <input type="date" name="delivered_on" defaultValue={defaultDate} style={{ fontSize: 12 }} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Mark sent"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

export function RunFiledForm({
  runId,
  filedOn,
  irisReceipt,
  notes,
}: {
  runId: string;
  filedOn: string | null;
  irisReceipt: string;
  notes: string;
}) {
  const [state, action, pending] = useActionState(recordRunFiled, initial);
  const [open, setOpen] = useState(false);

  return (
    <div style={{ marginTop: 10 }}>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {filedOn && !open ? (
        <p className="sub" style={{ margin: 0 }}>
          Filed {filedOn}
          {irisReceipt && ` · receipt ${irisReceipt}`}{" "}
          <button className="btn ghost" type="button" onClick={() => setOpen(true)}>
            Change
          </button>
        </p>
      ) : (
        <form action={action}>
          <input type="hidden" name="run_id" value={runId} />
          <div className="row2" style={{ alignItems: "flex-end" }}>
            <label className="field">
              Filed on
              <input type="date" name="filed_on" defaultValue={filedOn ?? ""} />
            </label>
            <label className="field">
              IRIS receipt
              <input name="iris_receipt" defaultValue={irisReceipt} />
            </label>
            <label className="field" style={{ flex: 2 }}>
              Notes
              <input name="notes" defaultValue={notes} />
            </label>
            <button className="btn" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Save"}
            </button>
          </div>
        </form>
      )}
    </div>
  );
}

export type RecipientRow = {
  id: string;
  legal_name: string;
  business_name: string;
  address_snapshot: string;
  tin_type: string | null;
  tin_last4: string | null;
  nonemployee_comp: number;
  consent_recorded: boolean;
  delivered_on: string | null;
  delivery_method: string | null;
};

export function RunPanel({
  run,
  recipients,
  defaultDate,
}: {
  run: {
    id: string;
    year: number;
    threshold: number;
    state_copy: boolean;
    generated_at: string;
    filed_on: string | null;
    iris_receipt: string;
    notes: string;
  };
  recipients: RecipientRow[];
  defaultDate: string;
}) {
  const total = recipients.reduce((s, r) => s + Number(r.nonemployee_comp), 0);
  const undelivered = recipients.filter((r) => !r.delivered_on).length;

  return (
    <div className="card" style={{ marginTop: 14, padding: 0 }}>
      <div style={{ padding: "16px 16px 0" }}>
        <h3>
          {run.year} run
          {run.filed_on ? (
            <span className="chip ok" style={{ marginLeft: 8 }}>
              filed {run.filed_on}
            </span>
          ) : (
            <span className="chip warn" style={{ marginLeft: 8 }}>
              not filed
            </span>
          )}
          {run.state_copy && (
            <span className="chip" style={{ marginLeft: 8 }}>
              Utah copy
            </span>
          )}
        </h3>
        <p className="sub" style={{ marginTop: 0 }}>
          {recipients.length} recipient{recipients.length === 1 ? "" : "s"} over{" "}
          {usd(Number(run.threshold))}, totalling {usd(total)}. Built{" "}
          {new Date(run.generated_at).toLocaleString()}.
          {undelivered > 0 && ` ${undelivered} still to send.`}
        </p>
        <FilingCsvButtons runId={run.id} />
        <p className="lock" style={{ marginTop: 8 }}>
          The filing CSV is a plain flat file for the CPA or a filing service. The IRIS CSV uses
          the portal&apos;s own field names — check its header row against the current IRS template
          before the first upload, because a revised template would not announce itself. Both files
          carry taxpayer numbers in full: they are built when you press the button and never stored.
        </p>
        <RunFiledForm
          runId={run.id}
          filedOn={run.filed_on}
          irisReceipt={run.iris_receipt}
          notes={run.notes}
        />
      </div>

      <table className="t">
        <thead>
          <tr>
            <th>Recipient</th>
            <th>Box 1</th>
            <th>Number</th>
            <th>Copy B</th>
            <th>Delivered</th>
          </tr>
        </thead>
        <tbody>
          {recipients.map((r) => (
            <tr key={r.id}>
              <td>
                <b>{r.legal_name}</b>
                <div style={{ fontSize: 12, color: "var(--muted)" }}>{r.address_snapshot}</div>
                {!r.consent_recorded && (
                  <div className="lock">has not agreed to electronic delivery — post it</div>
                )}
              </td>
              <td>{usd(Number(r.nonemployee_comp))}</td>
              <td style={{ fontSize: 12, color: "var(--muted)" }}>
                {r.tin_type} ending {r.tin_last4}
              </td>
              <td>
                <CopyBButton recipientId={r.id} name={r.legal_name} />
              </td>
              <td>
                <DeliveryForm
                  recipientId={r.id}
                  consent={r.consent_recorded}
                  deliveredOn={r.delivered_on}
                  method={r.delivery_method}
                  defaultDate={defaultDate}
                />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
