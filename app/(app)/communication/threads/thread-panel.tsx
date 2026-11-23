"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { PRACTICE_TZ, today } from "@/lib/constants";
import {
  CAN_LOG_CALLS,
  CAN_SEND_TEXTS,
  sendingTo,
  whyNot,
  type ThreadRow,
} from "@/lib/threads-board-shape";
import { addToReport, logCall, sendOnThread, type ThreadState } from "./actions";

/**
 * One client's thread: texts, logged calls and the counselor email filed on
 * their record, in one dated stream (Communications brief, Part 2).
 *
 * Four things can be done from here and nothing happens without one of them
 * being pressed. The reply box names the number it will send to and the day
 * that number agreed, because the number is the thing that gets this wrong: a
 * client, their partner and their daughter-in-law are three numbers on one
 * record, and two of them may not be textable.
 *
 * A role the policy will refuse is not shown a send box at all (ruling 6c).
 * What it is shown is Log a call, which is the thing it can do and had
 * nowhere to put until now.
 */

export type StreamItem = {
  item_key: string;
  channel: string;
  at: string;
  direction: string;
  who: string;
  body: string | null;
  status: string | null;
  media_url: string | null;
  media_type: string | null;
  ref_id: string;
  web_link: string | null;
  collected: boolean;
};

const initial: ThreadState = { error: null, ok: null };

const CHIPS = [
  { key: "all", label: "All" },
  { key: "Text", label: "Texts" },
  { key: "Call", label: "Calls" },
  { key: "Email", label: "Email" },
];

const stamp = (iso: string) =>
  new Date(iso).toLocaleString("en-US", {
    timeZone: PRACTICE_TZ,
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });

export function ThreadPanel({
  row,
  items,
  chip,
  role,
  categories,
}: {
  row: ThreadRow;
  items: StreamItem[];
  chip: string;
  role: string;
  categories: string[];
}) {
  const [sent, send, sending] = useActionState(sendOnThread, initial);
  const [called, call, calling] = useActionState(logCall, initial);
  const [filed, file] = useActionState(addToReport, initial);
  const [callOpen, setCallOpen] = useState(false);

  const to = sendingTo(row);
  const refusal = whyNot(to);
  const maySend = CAN_SEND_TEXTS.includes(role);
  const mayCall = CAN_LOG_CALLS.includes(role);
  const shown = chip === "all" ? items : items.filter((i) => i.channel === chip);

  return (
    <section className="card" aria-label={`Thread with ${row.client_name}`}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <div>
          <h2 className="h2" style={{ margin: 0 }}>
            <Link href={`/clients/${row.client_id}?tab=dashboard`}>{row.client_name}</Link>
          </h2>
          <p className="lock" style={{ margin: "2px 0 0" }}>
            {row.status}
            {row.waiting_hours !== null && ` · waiting ${Math.floor(row.waiting_hours / 24) || "<1"} day(s)`}
          </p>
        </div>
        <Link
          className="btn ghost"
          href="/communication/threads"
          style={{ textDecoration: "none", padding: "2px 10px" }}
        >
          Close
        </Link>
      </div>

      <div className="segmented" role="group" aria-label="Which channel" style={{ marginTop: 10 }}>
        {CHIPS.map((c) => (
          <Link
            key={c.key}
            href={`/communication/threads?c=${row.client_id}${c.key === "all" ? "" : `&chip=${c.key}`}`}
            className={c.key === chip ? "on" : undefined}
          >
            {c.label}
          </Link>
        ))}
      </div>

      {/* ── the stream ── */}
      <div style={{ marginTop: 12, maxHeight: 420, overflowY: "auto" }}>
        {shown.length === 0 ? (
          <p className="lock" style={{ margin: 0 }}>
            Nothing on this channel yet.
          </p>
        ) : (
          shown.map((i) => (
            <div key={i.item_key} style={{ padding: "8px 0", borderBottom: "1px solid var(--line)" }}>
              <div className="row2" style={{ gap: 6, flexWrap: "wrap", alignItems: "baseline" }}>
                <span className="chip">{i.channel}</span>
                <span className="chip">{i.direction === "in" ? "in" : "out"}</span>
                <span className="lock">{i.who}</span>
                <span className="lock">{stamp(i.at)}</span>
                {i.status === "failed" || i.status === "Not delivered" ? (
                  <span className="chip bad">not delivered</span>
                ) : null}
                {i.collected && <span className="chip ok">on the month</span>}
              </div>
              <div style={{ marginTop: 2 }}>
                {i.channel === "Email" && i.web_link ? (
                  <a href={i.web_link} target="_blank" rel="noopener noreferrer">
                    {i.body}
                  </a>
                ) : (
                  i.body
                )}
              </div>
              {i.media_url && (
                <a href={i.media_url} target="_blank" rel="noopener noreferrer" className="lock">
                  the picture they sent
                </a>
              )}
              {!i.collected && (
                <form action={file} style={{ marginTop: 4 }}>
                  <input type="hidden" name="channel" value={i.channel} />
                  <input type="hidden" name="ref" value={i.ref_id} />
                  <input type="hidden" name="client_id" value={row.client_id ?? ""} />
                  <button className="btn ghost" style={{ padding: "1px 8px" }}>
                    Add to report
                  </button>
                </form>
              )}
            </div>
          ))
        )}
      </div>
      {filed.error && <p className="bad lock">{filed.error}</p>}
      {filed.ok && <p className="lock">{filed.ok}</p>}

      {/* ── the reply ── */}
      {maySend ? (
        refusal ? (
          <div style={{ marginTop: 12 }}>
            <p className="lock" style={{ margin: 0 }}>
              {refusal}
            </p>
          </div>
        ) : (
          <form action={send} style={{ marginTop: 12 }}>
            <input type="hidden" name="client_id" value={row.client_id ?? ""} />
            <input type="hidden" name="phone" value={to?.phone ?? ""} />
            <label className="field">
              <span>
                Text {to?.whose === "Contact" ? `${to.whose_name} (${to.relationship})` : "them"} at{" "}
                {to?.phone}
                {to?.since ? ` — agreed ${to.since.slice(0, 10)}` : ""}
              </span>
              <textarea name="body" rows={3} maxLength={600} required />
            </label>
            <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
              <button className="btn" disabled={sending}>
                {sending ? "Sending…" : "Send text"}
              </button>
              <label className="lock">
                <input type="checkbox" name="later" value="yes" /> send when the window opens
              </label>
            </div>
            {sent.error && <p className="bad lock">{sent.error}</p>}
            {sent.ok && <p className="lock">{sent.ok}</p>}
          </form>
        )
      ) : (
        <p className="lock" style={{ marginTop: 12 }}>
          Your role does not send texts. Log the call instead.
        </p>
      )}

      {/* ── and the other three ── */}
      <div className="row2" style={{ gap: 8, marginTop: 12, flexWrap: "wrap" }}>
        {mayCall && (
          <button type="button" className="btn ghost" onClick={() => setCallOpen((v) => !v)}>
            Log a call
          </button>
        )}
        <Link className="btn ghost" href={`/mail/compose?client=${row.client_id}`} style={{ textDecoration: "none" }}>
          Email counselor
        </Link>
        <Link
          className="btn ghost"
          href={`/clients/${row.client_id}?tab=messages`}
          style={{ textDecoration: "none" }}
        >
          The record
        </Link>
      </div>

      {callOpen && mayCall && (
        <form action={call} style={{ marginTop: 10 }}>
          <input type="hidden" name="client_id" value={row.client_id ?? ""} />
          <label className="field">
            <span>What the call was about</span>
            <textarea name="text" rows={3} required />
          </label>
          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label className="field">
              <span>Service</span>
              <select name="category" defaultValue="General progress">
                {categories
                  .filter((c) => c !== "Personal")
                  .map((c) => (
                    <option key={c}>{c}</option>
                  ))}
              </select>
            </label>
            <label className="field">
              <span>When</span>
              <input type="date" name="on" defaultValue={today()} max={today()} />
            </label>
            <label className="field">
              <span>How it ended</span>
              <input name="outcome" placeholder="Spoke to them" />
            </label>
          </div>
          <button className="btn" disabled={calling}>
            {calling ? "…" : "Log the call"}
          </button>
          {called.error && <p className="bad lock">{called.error}</p>}
          {called.ok && <p className="lock">{called.ok}</p>}
        </form>
      )}
    </section>
  );
}
