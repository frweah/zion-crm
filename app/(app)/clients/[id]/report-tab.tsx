"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { sendReport, type SendReportState } from "./report-actions";
import { REPORT_PRESETS, type ReportPresetKey } from "@/lib/report-presets";

/**
 * Weekly / monthly client activity report.
 *
 * The report body is built on the server from notes, service hours, job
 * search, placements, counselor contacts and billing in the period. The
 * narrative underneath it is written by staff — USOR expects a written
 * progress report with each invoice, and it has to be someone's words.
 *
 * Emailing it is deliberately two steps: you see the exact text that will
 * leave the building, addressed to the counselor on the record, and then you
 * send it. Same path as a signed form, for the same reason — this is the one
 * screen where a mis-click reaches somebody outside the practice.
 */
export function ReportTab({
  clientId,
  clientName,
  kind,
  preset,
  anchor,
  start,
  end,
  text,
  counselorName,
  counselorEmail,
  canSend,
}: {
  clientId: string;
  clientName: string;
  kind: "Weekly" | "Monthly";
  preset: ReportPresetKey;
  anchor: string;
  start: string;
  end: string;
  text: string;
  counselorName: string;
  counselorEmail: string;
  canSend: boolean;
}) {
  const [narrative, setNarrative] = useState("");
  const [msg, setMsg] = useState("");
  const [confirming, setConfirming] = useState(false);

  const [sendState, sendAction, sending] = useActionState<SendReportState, FormData>(sendReport, {
    error: null,
    ok: null,
  });

  const current = REPORT_PRESETS.find((p) => p.key === preset) ?? REPORT_PRESETS[0];

  const full = narrative.trim() ? `${text}\n\nNARRATIVE\n${narrative.trim()}` : text;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(full);
      setMsg("Copied.");
    } catch {
      setMsg("Copy was blocked — select the report text below instead.");
    }
    setTimeout(() => setMsg(""), 2500);
  };

  const download = () => {
    const blob = new Blob([full], { type: "text/plain" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `${clientName.replace(/\s+/g, "_")}_${kind}_${start}.txt`;
    a.click();
    URL.revokeObjectURL(a.href);
  };

  const link = (k: string, a: string, p: string) =>
    `/clients/${clientId}?tab=report&kind=${k}&anchor=${a}&preset=${p}`;

  return (
    <>
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="row2">
          <div className="field" style={{ marginBottom: 0 }}>
            Period
            <div className="tabs" style={{ margin: "4px 0 0", borderBottom: 0 }}>
              <Link
                href={link("Weekly", anchor, preset)}
                className={kind === "Weekly" ? "on" : ""}
              >
                Weekly
              </Link>
              <Link
                href={link("Monthly", anchor, preset)}
                className={kind === "Monthly" ? "on" : ""}
              >
                Monthly
              </Link>
            </div>
          </div>

          <form className="field" style={{ maxWidth: 200, marginBottom: 0 }}>
            Date in period
            <input type="hidden" name="tab" value="report" />
            <input type="hidden" name="kind" value={kind} />
            <input
              type="date"
              name="anchor"
              defaultValue={anchor}
              onChange={(e) => {
                window.location.href = link(kind, e.target.value, preset);
              }}
            />
          </form>

          <span className="lock">
            {start} to {end}
          </span>

          <button className="btn ghost" type="button" onClick={copy}>
            Copy
          </button>
          <button className="btn ghost" type="button" onClick={download}>
            Download
          </button>
        </div>

        <div className="field" style={{ margin: "12px 0 0" }}>
          Report
          <div className="tabs" style={{ margin: "4px 0 0", borderBottom: 0, flexWrap: "wrap" }}>
            {REPORT_PRESETS.map((p) => (
              <Link
                key={p.key}
                href={link(kind, anchor, p.key)}
                className={p.key === preset ? "on" : ""}
              >
                {p.label}
              </Link>
            ))}
          </div>
          <p className="lock" style={{ margin: "6px 0 0" }}>
            {current.blurb}
          </p>
        </div>

        {msg && <div className="alert ok" style={{ marginTop: 10 }}>{msg}</div>}
      </div>

      <div className="card">
        <pre
          style={{
            margin: 0,
            whiteSpace: "pre-wrap",
            fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
            fontSize: 12.5,
            lineHeight: 1.55,
          }}
        >
          {text}
        </pre>
      </div>

      <div className="card" style={{ marginTop: 12 }}>
        <h3>Narrative</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          The written progress report USOR expects with each invoice. Copy, Download and the email
          all include whatever you write here.
        </p>
        <textarea
          rows={6}
          value={narrative}
          onChange={(e) => setNarrative(e.target.value)}
          placeholder="Services provided, the client's progress and engagement, barriers, and recommended next steps."
        />
        <p className="lock" style={{ margin: "8px 0 0" }}>
          Copying or downloading leaves no record. Emailing it saves the narrative to this
          client&apos;s notes.
        </p>
      </div>

      {canSend && (
        <div className="card" style={{ marginTop: 12 }}>
          <h3>Send to the counselor</h3>

          {sendState.error && <div className="alert bad">{sendState.error}</div>}
          {sendState.ok && <div className="alert ok">{sendState.ok}</div>}

          {!counselorEmail ? (
            <p className="sub" style={{ marginTop: 0 }}>
              No counselor email address on this client&apos;s record, so there is nowhere to send
              it. Add one on the{" "}
              <Link href={`/clients/${clientId}?tab=overview`}>Overview tab</Link>.
            </p>
          ) : !confirming || sendState.ok ? (
            // Back to one button once it has gone, so the send cannot be
            // repeated by pressing a button that is still sitting there.
            <>
              <p className="sub" style={{ marginTop: 0 }}>
                Goes to {counselorName || "the counselor"} at {counselorEmail}, from the practice
                address, and is logged as a counselor contact.
              </p>
              <button className="btn" type="button" onClick={() => setConfirming(true)}>
                Email to {counselorName || "counselor"}…
              </button>
            </>
          ) : (
            <>
              <p className="sub" style={{ marginTop: 0 }}>
                This is exactly what will be sent. Nothing has left yet.
              </p>
              <table className="t" style={{ marginBottom: 10 }}>
                <tbody>
                  <tr>
                    <td style={{ width: 90 }} className="lock">
                      To
                    </td>
                    <td>
                      {counselorName ? `${counselorName} · ` : ""}
                      {counselorEmail}
                    </td>
                  </tr>
                  <tr>
                    <td className="lock">Subject</td>
                    <td>
                      {current.label} — {clientName} — {start} to {end}
                    </td>
                  </tr>
                </tbody>
              </table>

              <pre
                style={{
                  margin: "0 0 12px",
                  maxHeight: 260,
                  overflow: "auto",
                  whiteSpace: "pre-wrap",
                  fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
                  fontSize: 12,
                  lineHeight: 1.5,
                  padding: 12,
                  background: "var(--bg)",
                  border: "1px solid var(--line)",
                  borderRadius: 8,
                }}
              >
                {full}
              </pre>

              <div className="row2">
                <form action={sendAction}>
                  <input type="hidden" name="client_id" value={clientId} />
                  <input type="hidden" name="kind" value={kind} />
                  <input type="hidden" name="preset" value={preset} />
                  <input type="hidden" name="start" value={start} />
                  <input type="hidden" name="end" value={end} />
                  <input type="hidden" name="narrative" value={narrative.trim()} />
                  <input type="hidden" name="to" value={counselorEmail} />
                  <button className="btn gold" type="submit" disabled={sending}>
                    {sending ? "Sending…" : `Send to ${counselorEmail}`}
                  </button>
                </form>
                <button className="btn ghost" type="button" onClick={() => setConfirming(false)}>
                  Cancel
                </button>
              </div>
            </>
          )}
        </div>
      )}
    </>
  );
}
