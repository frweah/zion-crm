"use client";

import { useState, useActionState } from "react";
import {
  addAuthorization,
  logServiceEntry,
  updateCompletion,
  createInvoice,
  setInvoiceStatus,
  type BillingState,
} from "./actions";
import {
  today,
  money,
  SERVICE_TYPES,
  SERVICE_DEFAULTS,
  COACHING_CODES,
} from "@/lib/constants";

const initial: BillingState = { error: null, ok: null };

type Option = { id: string; name: string };

export type AuthOption = {
  id: string;
  label: string;
  serviceType: string;
  rateType: string;
  rate: number;
  totalHours: number | null;
  used: number;
};

function Message({ state }: { state: BillingState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

export function AddAuthorizationForm({ clients }: { clients: Option[] }) {
  const [state, action, pending] = useActionState(addAuthorization, initial);
  const [service, setService] = useState("Job Coaching");
  const defaults = SERVICE_DEFAULTS[service];
  const [rateType, setRateType] = useState(defaults?.rateType ?? "Hourly");

  return (
    <div className="card">
      <h3>Add authorization</h3>
      <Message state={state} />
      <form action={action}>
        <div className="row2">
          <label className="field">
            Client
            <select name="client_id" required defaultValue="">
              <option value="">— choose —</option>
              {clients.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            Authorization #
            <input name="number" placeholder="V10…" required />
          </label>
          <label className="field">
            Service
            <select
              name="service_type"
              value={service}
              onChange={(e) => {
                setService(e.target.value);
                const d = SERVICE_DEFAULTS[e.target.value];
                if (d) setRateType(d.rateType);
              }}
            >
              {SERVICE_TYPES.map((s) => (
                <option key={s}>{s}</option>
              ))}
            </select>
          </label>
          <label className="field">
            Rate type
            <select
              name="rate_type"
              value={rateType}
              onChange={(e) => setRateType(e.target.value as "Hourly" | "Flat Fee")}
            >
              <option>Hourly</option>
              <option>Flat Fee</option>
            </select>
          </label>
        </div>

        <div className="row2" style={{ marginTop: 10 }}>
          <label className="field" style={{ maxWidth: 140 }}>
            Rate ($)
            <input
              name="rate"
              type="number"
              step="0.01"
              key={service}
              defaultValue={defaults?.rate ?? ""}
              required
            />
          </label>
          {rateType === "Hourly" && (
            <label className="field" style={{ maxWidth: 160 }}>
              Authorized hours
              <input name="total_hours" type="number" step="0.25" required />
            </label>
          )}
          <label className="field" style={{ maxWidth: 170 }}>
            Begin
            <input name="start_date" type="date" defaultValue={today()} />
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            End
            <input name="end_date" type="date" />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Required forms before payment
            <input name="requires_forms" placeholder="e.g. Form 93, Form 95" />
          </label>
        </div>

        <button className="btn gold" type="submit" disabled={pending} style={{ marginTop: 12 }}>
          {pending ? "Saving…" : "Save authorization"}
        </button>
      </form>
    </div>
  );
}

export function ServiceEntryForm({ auths }: { auths: AuthOption[] }) {
  const [state, action, pending] = useActionState(logServiceEntry, initial);
  const [authId, setAuthId] = useState("");

  const auth = auths.find((a) => a.id === authId);
  const remaining = auth?.totalHours != null ? auth.totalHours - auth.used : null;
  const isCoaching = auth?.serviceType === "Job Coaching";

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <Message state={state} />
      <form action={action}>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            Authorization
            <select
              name="auth_id"
              required
              value={authId}
              onChange={(e) => setAuthId(e.target.value)}
            >
              <option value="">— choose —</option>
              {auths.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.label}
                </option>
              ))}
            </select>
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Date
            <input name="date" type="date" max={today()} defaultValue={today()} required />
          </label>
          <label className="field" style={{ maxWidth: 110 }}>
            Hours
            <input name="hours" type="number" step="0.25" required />
          </label>
        </div>

        <div className="row2" style={{ marginTop: 10 }}>
          {isCoaching && (
            <>
              <label className="field">
                Primary service (USOR 95)
                <select name="primary_code" required>
                  <option value="">—</option>
                  {COACHING_CODES.map((c) => (
                    <option key={c} value={c.split(".")[0]}>
                      {c}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                Secondary service
                <select name="secondary_code" defaultValue="">
                  <option value="">—</option>
                  {COACHING_CODES.map((c) => (
                    <option key={c} value={c.split(".")[0]}>
                      {c}
                    </option>
                  ))}
                </select>
              </label>
            </>
          )}
          <label className="field" style={{ flex: 3 }}>
            Activity notes
            <input name="notes" />
          </label>
          <label style={{ fontSize: 12, whiteSpace: "nowrap" }}>
            <input type="checkbox" name="non_billable" style={{ width: "auto", marginRight: 4 }} />
            Non-billable
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Logging…" : "Log"}
          </button>
        </div>

        {auth && remaining !== null && (
          <div
            style={{
              fontSize: 12,
              marginTop: 10,
              color: remaining <= 0 ? "var(--bad)" : "var(--muted)",
            }}
          >
            {remaining <= 0
              ? `No hours left on ${auth.label.split(" · ")[0]} — request additional hours before logging more.`
              : `${remaining} hrs remaining on ${auth.label.split(" · ")[0]}.`}
          </div>
        )}
      </form>
    </div>
  );
}

export function CompletionRow({
  completion,
}: {
  completion: {
    id: string;
    auth_number: string;
    client_name: string;
    service_type: string;
    start_date: string | null;
    completion: string | null;
    billed: boolean;
    rate: number;
  };
}) {
  const [state, action, pending] = useActionState(updateCompletion, initial);

  return (
    <tr>
      <td>
        <b>{completion.auth_number}</b>
      </td>
      <td>{completion.client_name}</td>
      <td>{completion.service_type}</td>
      <td colSpan={2}>
        <form action={action} className="row2" style={{ gap: 6 }}>
          <input type="hidden" name="completion_id" value={completion.id} />
          <input
            name="start_date"
            type="date"
            max={today()}
            defaultValue={completion.start_date ?? ""}
            style={{ maxWidth: 150 }}
          />
          <input
            name="completion"
            type="date"
            max={today()}
            defaultValue={completion.completion ?? ""}
            style={{ maxWidth: 150 }}
          />
          <button className="btn ghost" type="submit" disabled={pending}>
            {pending ? "…" : "Save"}
          </button>
        </form>
        {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
      </td>
      <td>{money(completion.rate)}</td>
      <td>
        {completion.billed ? (
          <span className="chip ok">Yes</span>
        ) : completion.completion ? (
          <span className="chip warn">ready to invoice</span>
        ) : (
          <span className="lock">needs completion date</span>
        )}
      </td>
    </tr>
  );
}

export function NewInvoiceForm({ auths }: { auths: AuthOption[] }) {
  const [state, action, pending] = useActionState(createInvoice, initial);
  const [authId, setAuthId] = useState("");

  const auth = auths.find((a) => a.id === authId);
  const authorized =
    auth == null
      ? null
      : auth.rateType === "Flat Fee"
        ? auth.rate
        : (auth.totalHours ?? 0) * auth.rate;
  const suggested =
    auth == null ? "" : auth.rateType === "Flat Fee" ? auth.rate : auth.used * auth.rate;

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <h3>New invoice</h3>
      <Message state={state} />
      <form action={action}>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            Authorization
            <select name="auth_id" required value={authId} onChange={(e) => setAuthId(e.target.value)}>
              <option value="">— choose —</option>
              {auths.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.label}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            Invoice #
            <input name="number" required />
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            Date
            <input name="date" type="date" defaultValue={today()} />
          </label>
          <label className="field" style={{ maxWidth: 140 }}>
            Amount
            <input
              name="amount"
              type="number"
              step="0.01"
              key={authId}
              defaultValue={suggested}
              required
            />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Save draft"}
          </button>
        </div>

        {authorized !== null && (
          <p className="lock" style={{ margin: "10px 0 0" }}>
            {auth?.rateType === "Flat Fee"
              ? `Flat fee ${money(auth.rate)}.`
              : `${auth?.used ?? 0} hrs logged at ${money(auth?.rate)} — ${money(authorized)} authorized in total.`}{" "}
            The database refuses anything above the authorized amount.
          </p>
        )}
      </form>
    </div>
  );
}

export function InvoiceAction({
  invoiceId,
  status,
}: {
  invoiceId: string;
  status: string;
}) {
  const [state, action, pending] = useActionState(setInvoiceStatus, initial);
  const next = status === "Draft" ? "Sent" : status === "Sent" ? "Paid" : null;

  if (!next) return null;

  return (
    <>
      <form action={action}>
        <input type="hidden" name="invoice_id" value={invoiceId} />
        <input type="hidden" name="status" value={next} />
        <button className="btn ghost" type="submit" disabled={pending}>
          {pending ? "…" : `Mark ${next.toLowerCase()}`}
        </button>
      </form>
      {state.error && (
        <div style={{ color: "var(--bad)", fontSize: 12, maxWidth: 320, marginTop: 4 }}>
          {state.error}
        </div>
      )}
    </>
  );
}
