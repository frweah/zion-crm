"use client";

import { useActionState, useState } from "react";
import { makeReport, type MonthState } from "./month-actions";
import { REPORT_TEMPLATES, reportPeriodUnit } from "@/lib/report-shape";

const initial: MonthState = { error: null, ok: null };

/**
 * One of the five, for a period (owner, 30 Oct 2026).
 *
 * The period field changes with the template, because the two are not
 * independent: a weekly job search update has a Monday and the other four have
 * a month, and the database refuses anything else. A single date box would
 * have let somebody pick a Wednesday and read a constraint error.
 */
export function MakeReport({ clientId, month, week }: { clientId: string; month: string; week: string }) {
  const [state, action, pending] = useActionState(makeReport, initial);
  const [template, setTemplate] = useState<string>("Monthly client report");
  const weekly = reportPeriodUnit(template) === "week";

  return (
    <form action={action} className="card" style={{ display: "grid", gap: 8 }}>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      <input type="hidden" name="client_id" value={clientId} />

      <div className="row2" style={{ gap: 8, alignItems: "flex-end" }}>
        <label className="field" style={{ flex: 2 }} htmlFor="make-template">
          Which report
          <select
            id="make-template"
            name="template"
            value={template}
            onChange={(e) => setTemplate(e.target.value)}
          >
            {REPORT_TEMPLATES.map((t) => (
              <option key={t.key} value={t.key}>
                {t.key}
              </option>
            ))}
          </select>
        </label>
        <label className="field" htmlFor="make-period">
          {weekly ? "Week beginning" : "Month"}
          <input
            id="make-period"
            type="date"
            name="period"
            defaultValue={weekly ? week : month}
            key={weekly ? "week" : "month"}
          />
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Assembling…" : "Assemble it"}
        </button>
      </div>
      <p className="lock" style={{ margin: 0 }}>
        {REPORT_TEMPLATES.find((t) => t.key === template)?.note}
      </p>
    </form>
  );
}
