"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { useActionState } from "react";
import { PRACTICE_TZ } from "@/lib/constants";
import {
  CLOSED_GROUPS,
  GROUPS,
  TILES,
  canAssign,
  canSign,
  collected,
  groupFooter,
  overdue,
  type ReportBoardRow,
} from "@/lib/reports-board-shape";
import {
  BoardHead,
  BoardToolbar,
  ColumnsPanel,
  nextSort,
  useColumns,
  type BoardColumn,
  type Sort,
} from "../board-chrome";
import { setReportDue, setReportWriter, startReport, type BoardState } from "./board-actions";

/**
 * Reports, as a client-month board (owner, 20 November 2026).
 *
 * One row per client per month per report, grouped by how far each has got.
 * The survey it replaces is in docs/timing/reports.md: nineteen October
 * drafts, every one past its date, and the only thing in the practice that
 * said so was a Friday email to each person about their own.
 *
 * The same chrome as the other two boards - Billing › Authorizations and
 * Clients › Board - because this is the third of the same screen and a third
 * grid with its own toolbar is how three screens stop behaving alike.
 *
 * The tiles are filters rather than counts: each one is a sentence about a
 * row, asked in lib/reports-board-shape.ts, so the number on a tile and the
 * rows it filters to are the same arithmetic. Overdue is a tile and a flag on
 * the row, never a group - a report that is late is late at whatever stage it
 * reached, and a sixth group would take rows out of the five that say what
 * has been done to them.
 *
 * Two cells take input, both Reports' and Admin's: the writer and the date.
 * Everything else is a link to the screen that already does the work - the
 * month opens the report, a Signed pill opens the mail with the PDF ticked,
 * a week chip opens the week it is about.
 */

const COLUMNS: BoardColumn[] = [
  { key: "client", label: "Client" },
  { key: "counselor", label: "Counselor" },
  { key: "office", label: "Office" },
  { key: "month", label: "Month" },
  { key: "template", label: "Report" },
  { key: "writer", label: "Writer" },
  { key: "due", label: "Due" },
  { key: "left", label: "Days left", num: true },
  { key: "collected", label: "What's collected" },
  { key: "status", label: "Status" },
  { key: "sent", label: "Sent on" },
];

const initial: BoardState = { error: null, ok: null };

const day = (iso: string | null) =>
  iso
    ? new Date(iso.length === 10 ? `${iso}T12:00:00Z` : iso).toLocaleDateString("en-US", {
        timeZone: PRACTICE_TZ,
        month: "short",
        day: "numeric",
      })
    : "";

const monthName = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", {
    timeZone: PRACTICE_TZ,
    month: "long",
    year: "numeric",
  });

/** Who is writing it. Reports' and Admin's, which `report_hands` enforces. */
function WriterCell({
  row,
  staff,
  mayAssign,
}: {
  row: ReportBoardRow;
  staff: { id: string; name: string }[];
  mayAssign: boolean;
}) {
  const [state, act] = useActionState(setReportWriter, initial);
  if (!row.report_id || !mayAssign) {
    return <>{row.writer ?? <span className="chip warn">nobody</span>}</>;
  }
  return (
    <form action={act}>
      <input type="hidden" name="report_id" value={row.report_id} />
      <input type="hidden" name="client_id" value={row.client_id} />
      <select
        name="writer_id"
        aria-label={`Who is writing ${row.client_name}'s ${row.template}`}
        defaultValue={row.writer_id ?? ""}
        onChange={(e) => e.currentTarget.form?.requestSubmit()}
      >
        <option value="">nobody</option>
        {staff.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </select>
      {state.error && <div className="late">{state.error}</div>}
    </form>
  );
}

/** When it is wanted by. */
function DueCell({
  row,
  today,
  mayAssign,
}: {
  row: ReportBoardRow;
  today: string;
  mayAssign: boolean;
}) {
  const [state, act] = useActionState(setReportDue, initial);
  const late = overdue(row, today);
  if (!row.due_on) return <span className="lock">when asked for</span>;
  if (!row.report_id || !mayAssign) {
    return <span className={late ? "late" : undefined}>{day(row.due_on)}</span>;
  }
  return (
    <form action={act}>
      <input type="hidden" name="report_id" value={row.report_id} />
      <input type="hidden" name="client_id" value={row.client_id} />
      <input
        type="date"
        name="due_on"
        data-col="due"
        aria-label={`When ${row.client_name}'s ${row.template} is due`}
        defaultValue={row.due_on}
        onChange={(e) => e.currentTarget.form?.requestSubmit()}
      />
      {state.error && <div className="late">{state.error}</div>}
    </form>
  );
}

/**
 * The status, and the one thing to do about it.
 *
 * Not started is a button, because the row is built from the caseload and
 * there is nothing behind it yet. Signed is the Send button, which is the
 * owner's ruling 7: it opens the mail with the PDF ticked, and the mail
 * marks it Sent on send. The rest are pills that open the report.
 */
function StatusCell({
  row,
  today,
  me,
}: {
  row: ReportBoardRow;
  today: string;
  me: { id: string; role: string };
}) {
  const [state, act] = useActionState(startReport, initial);
  const late = overdue(row, today);
  const flag = late ? <span className="chip bad">Overdue</span> : null;

  if (!row.report_id) {
    return (
      <form action={act} style={{ display: "grid", gap: 4, justifyItems: "start", whiteSpace: "normal" }}>
        <input type="hidden" name="client_id" value={row.client_id} />
        <input type="hidden" name="period" value={row.period} />
        <input type="hidden" name="template" value={row.template} />
        <span className="row2" style={{ gap: 4 }}>
          <span className="chip">Not started</span>
          {flag}
        </span>
        <button className="btn ghost" type="submit">
          Assemble it
        </button>
        {state.error && <div className="late">{state.error}</div>}
      </form>
    );
  }

  const href = `/clients/${row.client_id}/reports/${row.period.slice(0, 7)}?template=${encodeURIComponent(row.template)}`;

  if (row.status === "Signed" && canSign(row, me)) {
    return (
      <span className="row2" style={{ gap: 4, whiteSpace: "normal" }}>
        <Link className="chip gold" href={`/mail/compose?client=${row.client_id}&report=${row.report_id}`}>
          Signed — send it
        </Link>
        {flag}
      </span>
    );
  }

  return (
    <span className="row2" style={{ gap: 4, whiteSpace: "normal" }}>
      <Link
        className={
          "chip " + (row.status === "Sent" ? "ok" : row.status === "Signed" ? "gold" : "")
        }
        href={href}
      >
        {row.status}
      </Link>
      {flag}
    </span>
  );
}

/** What the month has collected, as chips. The week chip opens the week. */
function CollectedCell({ row }: { row: ReportBoardRow }) {
  return (
    <span className="row2" style={{ gap: 4, whiteSpace: "normal" }}>
      {collected(row).map((c) =>
        c.key === "weeks" ? (
          <Link
            key={c.key}
            className={"chip" + (c.bad ? " bad" : "")}
            href={
              `/clients/${row.client_id}/reports` +
              (row.first_unconfirmed_week ? `#week-${row.first_unconfirmed_week}` : "#weeks")
            }
          >
            {c.label}
          </Link>
        ) : (
          <span key={c.key} className={"chip" + (c.bad ? " bad" : "")}>
            {c.label}
          </span>
        ),
      )}
    </span>
  );
}

export function ReportsBoard({
  rows,
  staff,
  today,
  me,
  toFileWaiting,
}: {
  rows: ReportBoardRow[];
  staff: { id: string; name: string }[];
  today: string;
  me: { id: string; role: string };
  /** How many are in the To file panel above, which is a count and not a filter. */
  toFileWaiting: number;
}) {
  const [q, setQ] = useState("");
  const [counselor, setCounselor] = useState("");
  const [writer, setWriter] = useState("");
  const [template, setTemplate] = useState("");
  const [tile, setTile] = useState<string | null>(null);
  const [sort, setSort] = useState<Sort>({ key: "", dir: 1 });
  const [shut, setShut] = useState<Set<string>>(new Set(CLOSED_GROUPS));
  const { hidden, toggle, showColumns, setShowColumns, shown } = useColumns(COLUMNS, []);
  const mayAssign = canAssign(me.role);

  const counselors = useMemo(
    () => [...new Set(rows.map((r) => r.counselor).filter(Boolean) as string[])].sort(),
    [rows],
  );
  const writers = useMemo(
    () => [...new Set(rows.map((r) => r.writer).filter(Boolean) as string[])].sort(),
    [rows],
  );
  const templates = useMemo(() => [...new Set(rows.map((r) => r.template))].sort(), [rows]);

  const matching = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const chosen = TILES.find((t) => t.key === tile);
    return rows.filter((r) => {
      if (counselor && r.counselor !== counselor) return false;
      if (writer && r.writer !== writer) return false;
      if (template && r.template !== template) return false;
      if (chosen && !chosen.holds(r, today)) return false;
      if (!needle) return true;
      return (
        r.client_name.toLowerCase().includes(needle) ||
        r.template.toLowerCase().includes(needle) ||
        (r.writer ?? "").toLowerCase().includes(needle) ||
        (r.counselor ?? "").toLowerCase().includes(needle)
      );
    });
  }, [rows, q, counselor, writer, template, tile, today]);

  const sorted = useMemo(() => {
    if (!sort.key) return matching;
    const value = (r: ReportBoardRow): string | number => {
      switch (sort.key) {
        case "client": return r.client_name;
        case "counselor": return r.counselor ?? "";
        case "office": return r.office ?? "";
        case "month": return r.period;
        case "template": return r.template;
        case "writer": return r.writer ?? "";
        case "due": return r.due_on ?? "";
        case "left": return r.days_left ?? 9999;
        case "collected": return r.notes + r.contacts;
        case "status": return r.status;
        case "sent": return r.sent_at ?? "";
        default: return "";
      }
    };
    return [...matching].sort((a, b) => {
      const x = value(a);
      const y = value(b);
      const n =
        typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y));
      return n * sort.dir;
    });
  }, [matching, sort]);

  const toggleGroup = (group: string) =>
    setShut((s) => {
      const n = new Set(s);
      if (n.has(group)) n.delete(group);
      else n.add(group);
      return n;
    });

  let rowNumber = 0;

  const cell = (r: ReportBoardRow, key: string) => {
    switch (key) {
      case "client":
        return (
          <Link href={`/clients/${r.client_id}?tab=dashboard`} style={{ fontWeight: 600 }}>
            {r.client_name}
          </Link>
        );
      case "counselor": return r.counselor ?? <span className="lock">not set</span>;
      case "office": return r.office ?? "";
      case "month": return monthName(r.period);
      case "template": return r.template;
      case "writer": return <WriterCell row={r} staff={staff} mayAssign={mayAssign} />;
      case "due": return <DueCell row={r} today={today} mayAssign={mayAssign} />;
      case "left":
        if (r.days_left === null) return "";
        return (
          <span className={r.days_left < 0 ? "late" : undefined}>{r.days_left}</span>
        );
      case "collected": return <CollectedCell row={r} />;
      case "status": return <StatusCell row={r} today={today} me={me} />;
      case "sent":
        return r.sent_at ? (
          <>
            {day(r.sent_at)}
            {r.sent_to && <div className="lock">{r.sent_to}</div>}
          </>
        ) : (
          ""
        );
      default: return "";
    }
  };

  return (
    <>
      <div className="tiles no-print">
        {TILES.map((t) => {
          const n = rows.filter((x) => t.holds(x, today)).length;
          const on = tile === t.key;
          return (
            <button
              key={t.key}
              type="button"
              className={`tile${on ? " tile-lead" : ""}${n > 0 && !on ? " tile-bad" : ""}`}
              aria-pressed={on}
              onClick={() => setTile(on ? null : t.key)}
              style={{ textAlign: "left", cursor: "pointer" }}
            >
              <span className="tile-label">{t.label}</span>
              <span className="tile-value">{n}</span>
              <span className="tile-note">
                {on ? "showing these — press to clear" : "press to show these"}
              </span>
            </button>
          );
        })}
        {/* The fifth is a count, not a filter: it is about the panel above
            rather than about a row in the table, and a tile that filtered the
            board to nothing would be a tile that lies. With nothing waiting
            there is no panel to open, so it does not offer to open one. */}
        {toFileWaiting > 0 ? (
          <a className="tile" href="#to-file">
            <span className="tile-label">To file</span>
            <span className="tile-value">{toFileWaiting}</span>
            <span className="tile-note">press to open the panel</span>
          </a>
        ) : (
          <div className="tile">
            <span className="tile-label">To file</span>
            <span className="tile-value">0</span>
            <span className="tile-note">nothing waiting</span>
          </div>
        )}
      </div>

      <BoardToolbar
        q={q}
        onQ={setQ}
        label="Search a report"
        placeholder="Client, report, writer or counselor"
        right={
          <button type="button" className="btn ghost" onClick={() => setShowColumns((v) => !v)}>
            Columns
          </button>
        }
      >
        <select aria-label="Report" value={template} onChange={(e) => setTemplate(e.target.value)}>
          <option value="">Every report</option>
          {templates.map((t) => (
            <option key={t} value={t}>{t}</option>
          ))}
        </select>
        <select aria-label="Writer" value={writer} onChange={(e) => setWriter(e.target.value)}>
          <option value="">Anybody writing</option>
          {writers.map((w) => (
            <option key={w} value={w}>{w}</option>
          ))}
        </select>
        <select aria-label="Counselor" value={counselor} onChange={(e) => setCounselor(e.target.value)}>
          <option value="">Every counselor</option>
          {counselors.map((c) => (
            <option key={c} value={c}>{c}</option>
          ))}
        </select>
        <span className="lock">Grouped by status</span>
      </BoardToolbar>

      {showColumns && <ColumnsPanel columns={COLUMNS} hidden={hidden} toggle={toggle} />}

      <div className="board-wrap">
        <table
          className="board"
          data-layout="one row per client, month and report, grouped by how far each has got"
        >
          <BoardHead columns={shown} sort={sort} onSort={(k) => setSort((s) => nextSort(s, k))} />

          {GROUPS.map((group) => {
            const inGroup = sorted.filter((r) => r.status === group);
            const foot = groupFooter(inGroup, today);
            const isShut = shut.has(group);
            return (
              <tbody key={group}>
                <tr className="group">
                  <th colSpan={shown.length + 1} scope="colgroup">
                    <div className="group-bar">
                      <button
                        type="button"
                        className="toggle"
                        aria-expanded={!isShut}
                        onClick={() => toggleGroup(group)}
                      >
                        {isShut ? "▸" : "▾"} <span className="name">{group}</span>
                      </button>
                      <span>
                        {foot.count} {foot.count === 1 ? "report" : "reports"}
                      </span>
                      <span className="totals">
                        {foot.overdue} overdue · {foot.missing} missing a source
                      </span>
                    </div>
                  </th>
                </tr>

                {!isShut && inGroup.length === 0 && (
                  <tr>
                    <td className="pin-n" />
                    <td className="pin-client lock" colSpan={shown.length}>
                      Nothing at this stage
                    </td>
                  </tr>
                )}

                {!isShut &&
                  inGroup.map((r) => {
                    rowNumber += 1;
                    return (
                      <tr key={r.row_key}>
                        <td className="pin-n">{rowNumber}</td>
                        {shown.map((c, i) => (
                          <td
                            key={c.key}
                            className={[i === 0 ? "pin-client" : "", c.num ? "num" : ""]
                              .filter(Boolean)
                              .join(" ")}
                          >
                            {cell(r, c.key)}
                          </td>
                        ))}
                      </tr>
                    );
                  })}
              </tbody>
            );
          })}
        </table>
      </div>

      {sorted.length === 0 && (
        <p className="empty">
          {rows.length === 0
            ? "No report is owed this month — the caseload is empty."
            : "Nothing matches — clear the search, the filters or the tile."}
        </p>
      )}
    </>
  );
}
