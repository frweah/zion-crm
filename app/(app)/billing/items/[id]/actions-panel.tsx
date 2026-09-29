"use client";

import { useState } from "react";
import { money } from "@/lib/constants";
import type { ItemRow } from "@/lib/billing-items";
import {
  markServiceComplete,
  resolveZeroHours,
  sendForReview,
  submitItem,
  requestCorrection,
  recordPayment,
  closeItem,
  reopenItem,
} from "../../item-actions";

/**
 * The moves this item can make now, and only those.
 *
 * An item late in its life should not offer "mark the service complete", and
 * one nobody has finished should not offer "submit": a screen that offers
 * every action at every moment is a screen that has to be read carefully
 * before it can be used at all.
 */
export function ItemActions({ item, ready, isAdmin }: { item: ItemRow; ready: boolean; isAdmin: boolean }) {
  const [open, setOpen] = useState<string | null>(null);
  const before = (s: string) => item.status === s;
  const sent = ["Submitted", "Pending", "Correction needed"].includes(item.status);

  if (item.status === "Closed") {
    return (
      <section className="page-section">
        <h2 className="h2">Closed</h2>
        <p className="lock">{item.closed_reason}</p>
        {isAdmin && (
          <form action={reopenItem.bind(null, item.id)}>
            <button className="btn ghost" type="submit">
              Reopen it
            </button>
          </form>
        )}
      </section>
    );
  }

  return (
    <section className="page-section">
      <h2 className="h2">What happens next</h2>
      <div className="day-actions">
        {item.zero_hours_flagged && (
          <>
            <form action={resolveZeroHours.bind(null, item.id)} style={{ display: "inline" }}>
              <input type="hidden" name="answer" value="not logged" />
              <button className="btn" type="submit">
                The hours were not logged
              </button>
            </form>
            <form action={resolveZeroHours.bind(null, item.id)} style={{ display: "inline" }}>
              <input type="hidden" name="answer" value="no service" />
              <button className="btn ghost" type="submit">
                No service this month
              </button>
            </form>
          </>
        )}
        {(before("Service in progress") || before("Authorization received")) && (
          <button className="btn" type="button" onClick={() => setOpen(open === "complete" ? null : "complete")}>
            Mark the service complete
          </button>
        )}
        {(before("Service period complete") || before("Ready for billing")) && (
          <form action={sendForReview.bind(null, item.id)} style={{ display: "inline" }}>
            <button className="btn" type="submit">
              Send for review
            </button>
          </form>
        )}
        {before("Billing review") && (
          <button
            className="btn"
            type="button"
            disabled={!ready}
            title={ready ? undefined : "Some checks above still fail."}
            onClick={() => setOpen(open === "submit" ? null : "submit")}
          >
            Submit the packet
          </button>
        )}
        {sent && (
          <>
            <button className="btn ghost" type="button" onClick={() => setOpen(open === "correction" ? null : "correction")}>
              It came back for correction
            </button>
            <button className="btn" type="button" onClick={() => setOpen(open === "payment" ? null : "payment")}>
              Record a payment
            </button>
          </>
        )}
        <button className="btn ghost" type="button" onClick={() => setOpen(open === "close" ? null : "close")}>
          Close it
        </button>
      </div>

      {open === "complete" && (
        <form action={markServiceComplete.bind(null, item.id)} className="card" style={{ marginTop: 12 }}>
          <p className="lock">
            When the work actually happened — not the authorization&rsquo;s dates, which answer a different question.
          </p>
          <label>
            Started
            <input type="date" name="service_start" defaultValue={item.service_start ?? ""} required />
          </label>
          <label>
            Finished
            <input type="date" name="service_end" defaultValue={item.service_end ?? ""} required />
          </label>
          <button className="btn" type="submit">
            Save
          </button>
        </form>
      )}

      {open === "submit" && (
        <form action={submitItem.bind(null, item.id)} className="card" style={{ marginTop: 12 }}>
          <p className="lock">
            The packet is the signed authorization and the completed {item.usor_forms?.length ? "form" : "paperwork"}.
            USOR assigns the invoice number; it is recorded here when the warrant arrives.
          </p>
          <label>
            To
            <input type="email" name="recipient" defaultValue={item.recipient ?? ""} required />
          </label>
          <button className="btn" type="submit">
            Send it
          </button>
        </form>
      )}

      {open === "correction" && (
        <form action={requestCorrection.bind(null, item.id)} className="card" style={{ marginTop: 12 }}>
          <label>
            What has to change
            <textarea name="note" rows={3} required defaultValue={item.correction_note ?? ""} />
          </label>
          <button className="btn" type="submit">
            Record it
          </button>
        </form>
      )}

      {open === "payment" && (
        <form action={recordPayment.bind(null, item.id)} className="card" style={{ marginTop: 12 }}>
          <p className="lock">
            A warrant records itself. This is for a payment that arrived another way, and it is recorded as a payment
            somebody entered.
          </p>
          <label>
            Paid on
            <input type="date" name="paid_on" required />
          </label>
          <label>
            Amount
            <input type="number" step="0.01" name="paid_amount" defaultValue={item.value ?? undefined} required />
          </label>
          <label>
            Warrant number
            <input type="text" name="warrant" />
          </label>
          <button className="btn" type="submit">
            Record {money(item.value)}
          </button>
        </form>
      )}

      {open === "close" && (
        <form action={closeItem.bind(null, item.id)} className="card" style={{ marginTop: 12 }}>
          <p className="lock">
            Closing is for work that ended without payment. Paid is the normal end, and this is not a way to reach it.
          </p>
          <label>
            Why
            <input type="text" name="reason" required placeholder="The client stopped services before billing" />
          </label>
          <button className="btn ghost" type="submit">
            Close it
          </button>
        </form>
      )}
    </section>
  );
}
