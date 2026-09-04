"use client";

import { useState } from "react";
import Link from "next/link";

/**
 * Weekly / monthly client activity report.
 *
 * The report body is built on the server from notes, service hours, stage
 * changes, placements, counselor contacts and billing in the period. The
 * narrative underneath it is written by staff — USOR expects a written
 * progress report with each invoice, and it has to be someone's words.
 */
export function ReportTab({
  clientId,
  clientName,
  kind,
  anchor,
  start,
  end,
  text,
}: {
  clientId: string;
  clientName: string;
  kind: "Weekly" | "Monthly";
  anchor: string;
  start: string;
  end: string;
  text: string;
}) {
  const [narrative, setNarrative] = useState("");
  const [msg, setMsg] = useState("");

  const full = narrative.trim()
    ? `${text}\n\nNARRATIVE\n${narrative.trim()}`
    : text;

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

  const link = (k: string, a: string) =>
    `/clients/${clientId}?tab=report&kind=${k}&anchor=${a}`;

  return (
    <>
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="row2">
          <div className="field" style={{ marginBottom: 0 }}>
            Period
            <div className="tabs" style={{ margin: "4px 0 0", borderBottom: 0 }}>
              <Link href={link("Weekly", anchor)} className={kind === "Weekly" ? "on" : ""}>
                Weekly
              </Link>
              <Link href={link("Monthly", anchor)} className={kind === "Monthly" ? "on" : ""}>
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
                window.location.href = link(kind, e.target.value);
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
          The written progress report USOR expects with each invoice. Copy and Download include
          whatever you write here.
        </p>
        <textarea
          rows={6}
          value={narrative}
          onChange={(e) => setNarrative(e.target.value)}
          placeholder="Services provided, the client's progress and engagement, barriers, and recommended next steps."
        />
        <p className="lock" style={{ margin: "8px 0 0" }}>
          Not saved to the client record yet — copy or download it before leaving this tab.
        </p>
      </div>
    </>
  );
}
