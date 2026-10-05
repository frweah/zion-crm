"use client";

import { useState } from "react";
import { today } from "@/lib/constants";

/**
 * A statement of hours, drawn up on the spot (Rei, Oct 2026).
 *
 * Pick the dates - or leave them and let it offer last month, which is what
 * somebody is nearly always after - and it opens the PDF: every session in
 * the range, the total, and a line for the employer to sign. Admin can draw
 * one up for anybody, one employee at a time, because a statement is a
 * document about one person's work and a combined one would be nobody's.
 *
 * It opens rather than downloads, so the person can look at it before anybody
 * signs anything.
 */
function lastMonth(): { from: string; to: string } {
  const now = new Date(`${today()}T12:00:00`);
  const first = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const last = new Date(now.getFullYear(), now.getMonth(), 0);
  const iso = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  return { from: iso(first), to: iso(last) };
}

export function StatementCard({ staff }: { staff: { id: string; name: string }[] }) {
  const month = lastMonth();
  const [from, setFrom] = useState(month.from);
  const [to, setTo] = useState(month.to);
  const [who, setWho] = useState("");

  const href = `/api/hours/statement?from=${from}&to=${to}${who ? `&staff=${who}` : ""}`;

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <h3 style={{ marginTop: 0 }}>Statement of hours</h3>
      <div className="row2" style={{ alignItems: "flex-end" }}>
        <label className="field" style={{ maxWidth: 190 }}>
          From
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </label>
        <label className="field" style={{ maxWidth: 190 }}>
          To
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </label>
        {staff.length > 0 && (
          <label className="field" style={{ maxWidth: 230 }}>
            Whose
            <select value={who} onChange={(e) => setWho(e.target.value)}>
              <option value="">Mine</option>
              {staff.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </label>
        )}
        <a
          className="btn gold"
          href={href}
          target="_blank"
          rel="noopener noreferrer"
          style={{ textDecoration: "none" }}
        >
          Open the statement
        </a>
      </div>
      <p className="lock" style={{ margin: "8px 0 0" }}>
        Every session in the range, the total, and a line for the employer to sign. Corrected sessions are shown struck
        through and counted as nothing, so the page matches the record it came from.
      </p>
    </div>
  );
}
