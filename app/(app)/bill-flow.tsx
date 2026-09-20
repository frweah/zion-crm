"use client";

import { useActionState, useEffect, useState } from "react";
import Link from "next/link";
import { startBilling, type VisitState } from "./clients/[id]/visit-actions";
import { signaturePreview } from "./paperwork/signature-actions";
import { today, serviceCode } from "@/lib/constants";
import { stageForService, dueDateFor } from "@/lib/crp-pathway";

const initial: VisitState = { error: null, ok: null };

export type BillOption = {
  authId: string;
  label: string;
  service: string;
  number: string;
  price: string;
  status: string;
  /** Whether the authorization's own PDF is on the record to attach. */
  hasPdf: boolean;
  /** The forms this authorization's service needs before it can be billed. */
  templates: { id: string; usor: string; name: string; monthly: boolean; outstanding: boolean }[];
};

/**
 * Report and bill, in three steps: which authorization, the form with what is
 * already known on it, and where it goes.
 *
 * One component, used by the panel on a client's record and by the screen at
 * /billing/report. Two copies of this would drift, and the one drifting would
 * be the one somebody was billing from.
 *
 * Beside each step is what the CRP pathway says about it (lib/crp-pathway.ts)
 * - which date belongs on the invoice, what has to be true before it may be
 * billed, and when the paperwork is due. The CRM's own rules still decide
 * what actually happens; this is what USOR published, where somebody can see
 * it while they work rather than in a PDF on a desktop.
 */
export function BillFlow({
  clientId,
  bills,
  counselorName,
  agency,
  preparedBy,
  billingOffice,
}: {
  clientId: string;
  bills: BillOption[];
  counselorName: string;
  agency: string;
  preparedBy: string;
  billingOffice: string | null;
}) {
  const [authId, setAuthId] = useState(bills[0]?.authId ?? "");
  const [templateId, setTemplateId] = useState<string | null>(null);
  const [month, setMonth] = useState(today().slice(0, 7));
  const [signature, setSignature] = useState<string | null>(null);
  const [state, action, pending] = useActionState(startBilling, initial);

  const chosen = bills.find((b) => b.authId === authId) ?? bills[0];
  const form =
    chosen?.templates.find((t) => t.id === templateId) ??
    chosen?.templates.find((t) => t.outstanding) ??
    chosen?.templates[0];
  const stage = chosen ? stageForService(chosen.service) : null;
  const due = dueDateFor(stage, month);
  const late = due !== null && due < today();

  // Their signature, fetched once rather than on every view of a record: it
  // is a signed link with a short life, and most visits are not about billing.
  useEffect(() => {
    if (signature !== null) return;
    let live = true;
    void signaturePreview().then((url) => {
      if (live) setSignature(url ?? "");
    });
    return () => {
      live = false;
    };
  }, [signature]);

  if (bills.length === 0) {
    return (
      <p className="empty" style={{ margin: 0 }}>
        This client has no open authorization that bills on a form, so there is nothing to report on yet.
      </p>
    );
  }

  return (
    <form action={action} className="bill-flow">
      {state.error && <div className="alert bad">{state.error}</div>}
      <input type="hidden" name="client_id" value={clientId} />
      <input type="hidden" name="auth_id" value={chosen?.authId ?? ""} />
      <input type="hidden" name="template_id" value={form?.id ?? ""} />
      <input type="hidden" name="month" value={month} />

      {/* 1 — which authorization. Every service the client is authorized for,
          prefixed with its code, rather than one hidden in a dropdown. */}
      <section>
        <h4 className="bill-step">
          <span className="bill-num">1</span> Authorization
        </h4>
        <ul className="bill-auths">
          {bills.map((b) => (
            <li key={b.authId}>
              <button
                type="button"
                className={b.authId === chosen?.authId ? "on" : undefined}
                aria-pressed={b.authId === chosen?.authId}
                onClick={() => {
                  setAuthId(b.authId);
                  setTemplateId(null);
                }}
              >
                <span className="bill-code">{serviceCode(b.service)}</span>
                <span className="bill-auth-main">
                  <b>{b.number || "No V-number"}</b>
                  <span className="lock">
                    {b.service} · {b.price}
                  </span>
                </span>
                <span className="chip">{b.status}</span>
              </button>
            </li>
          ))}
        </ul>
      </section>

      {/* 2 — the form, what it already knows, and what the pathway asks. */}
      <section>
        <h4 className="bill-step">
          <span className="bill-num">2</span> Form, pre-filled
        </h4>

        {chosen && chosen.templates.length > 1 && (
          <div className="segmented" role="group" aria-label="Which form" style={{ marginBottom: 8 }}>
            {chosen.templates.map((t) => (
              <button
                key={t.id}
                type="button"
                className={t.id === form?.id ? "on" : undefined}
                onClick={() => setTemplateId(t.id)}
              >
                {t.usor}
                {t.outstanding ? "" : " done"}
              </button>
            ))}
          </div>
        )}

        {form && (
          <>
            <p className="sub" style={{ margin: "0 0 6px" }}>
              <b>{form.usor}</b> — {form.name}
              {form.outstanding ? "" : " · already done for this authorization"}
            </p>
            <dl className="bill-facts">
              <dt>Authorization</dt>
              <dd>{chosen?.number || "—"}</dd>
              <dt>Counselor</dt>
              <dd>{counselorName || "not set"}</dd>
              <dt>Agency</dt>
              <dd>{agency}</dd>
              <dt>Prepared by</dt>
              <dd>{preparedBy}</dd>
              <dt>Signature</dt>
              <dd>
                {signature ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={signature} alt="Your signature" className="bill-sig" />
                ) : signature === "" ? (
                  <span className="lock">
                    Your typed name and the time. <Link href="/paperwork">Add a signature image</Link>
                  </span>
                ) : (
                  <span className="lock">…</span>
                )}
              </dd>
              <dt>Report date</dt>
              <dd>
                {new Date().toLocaleDateString("en-US", { timeZone: "America/Denver" })}{" "}
                <span className="lock">defaults to today</span>
              </dd>
            </dl>

            {form.monthly && (
              <label className="field" style={{ maxWidth: 200 }}>
                Month
                <input type="month" value={month} onChange={(e) => setMonth(e.target.value)} />
              </label>
            )}

            <ul className="bill-files" aria-label="What will be attached">
              <li className="on">{form.usor} report, signed</li>
              <li className={chosen?.hasPdf ? "on" : undefined}>
                {chosen?.hasPdf ? `${chosen.number} authorization PDF` : "No authorization PDF on the record"}
              </li>
            </ul>

            {stage && (
              <div className="bill-pathway">
                <p>
                  <b>{stage.label}</b>, as USOR sets it out.
                </p>
                <dl>
                  <dt>Invoice date</dt>
                  <dd>{stage.invoiceDate}</dd>
                  <dt>Bill it when</dt>
                  <dd>{stage.billsWhen}</dd>
                  {stage.dueBy && (
                    <>
                      <dt>Paperwork due</dt>
                      <dd>
                        {stage.dueBy}
                        {due && (
                          <>
                            {" — "}
                            <span className={late ? "chip bad" : "chip"}>
                              {new Date(`${due}T00:00:00`).toLocaleDateString("en-US", {
                                month: "short",
                                day: "numeric",
                              })}
                              {late ? " · past" : ""}
                            </span>
                          </>
                        )}
                      </dd>
                    </>
                  )}
                  {stage.fees.length > 0 && (
                    <>
                      <dt>Published fee</dt>
                      <dd>
                        {stage.fees
                          .map((f) => `${f.label} $${f.amount.toLocaleString("en-US")}`)
                          .join(" · ")}
                        <span className="lock"> — the authorization&apos;s own rate is what is billed</span>
                      </dd>
                    </>
                  )}
                </dl>
              </div>
            )}

            <p className="lock" style={{ margin: "6px 0 0" }}>
              The static fields fill themselves. You enter the visit and service details.
            </p>
          </>
        )}
      </section>

      {/* 3 — where it goes. */}
      <section>
        <h4 className="bill-step">
          <span className="bill-num">3</span> Counselor and send
        </h4>
        <p className="sub" style={{ marginTop: 0 }}>
          It goes to {billingOffice ? <b>{billingOffice}</b> : "the billing office"} with{" "}
          <b>{counselorName || "the counselor"}</b> copied in, the signed form and the authorization attached. You see
          the addresses, the subject and the whole message on the next screen, and nothing sends without your tap.
        </p>
        <button className="btn gold" type="submit" disabled={pending || !form}>
          {pending ? "Opening…" : "Open the form"}
        </button>
      </section>
    </form>
  );
}
