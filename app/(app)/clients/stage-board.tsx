"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { useActionState } from "react";
import { PRACTICE_TZ, STAGES, stageLabel, stageNote, stageToken } from "@/lib/constants";
import {
  CHANNEL,
  LONG_IN_STAGE,
  OUT_OF_CONTACT,
  TILES,
  averageDays,
  daysSince,
  groupFooter,
  reportOverdue,
  taskOverdue,
  outOfContact,
  type ClientBoardRow,
} from "@/lib/clients-board-shape";
import {
  BoardHead,
  BoardToolbar,
  ColumnsPanel,
  nextSort,
  useColumns,
  type BoardColumn,
  type Sort,
} from "../board-chrome";
import { setAssignedStaff, type BoardState } from "./board-actions";
import { setTaskDue } from "../tasks/actions";

/**
 * Clients › Board, as a stage board (owner, 17 November 2026).
 *
 * The seven stage columns became seven groups of one list, for the reason the
 * billing board became one: a column of cards cannot be searched, sorted or
 * compared, and the question people actually bring to this screen - who has
 * nobody looking after them, who has not been contacted, whose authorization
 * is about to run out - is a question about a column of a table.
 *
 * The tiles along the top are filters rather than counts. Each one is a
 * sentence about a row (`lib/clients-board-shape.ts`), so the number on a
 * tile and the rows it filters to are the same arithmetic run twice, and
 * cannot disagree.
 *
 * Two cells take input: who the client is assigned to, and when the next task
 * is due. Both go through the paths that already exist - a write to the
 * client, which the directory log records, and `setTaskDue`, which is the
 * same function the task list calls. Everything else on the row is read.
 *
 * No money, no warrant, no Personal note, no transcript: this screen is the
 * whole team's.
 */

const COLUMNS: BoardColumn[] = [
  { key: "client", label: "Client" },
  { key: "counselor", label: "Counselor" },
  { key: "office", label: "Office" },
  { key: "assigned", label: "Assigned staff" },
  { key: "job", label: "Job status" },
  { key: "contact", label: "Last contact" },
  { key: "task", label: "Next task" },
  { key: "days", label: "Days in stage", num: true },
  { key: "report", label: "This month's report" },
  { key: "attention", label: "Attention" },
  { key: "stage", label: "Stage" },
  // On the Clients list, and here when somebody asks for them.
  { key: "goal", label: "Goal" },
  { key: "services", label: "Services" },
  { key: "billingOffice", label: "Billing office" },
  { key: "funding", label: "Funding source" },
  { key: "availability", label: "Availability" },
  { key: "applied", label: "Applied (7d)", num: true },
  { key: "interview", label: "Next interview" },
  { key: "note", label: "Last note" },
];

const HIDDEN_BY_DEFAULT = [
  "goal",
  "services",
  "billingOffice",
  "funding",
  "availability",
  "applied",
  "interview",
  "note",
];

const day = (iso: string | null) =>
  iso
    ? new Date(iso.length === 10 ? `${iso}T00:00:00` : iso).toLocaleDateString("en-US", {
        timeZone: PRACTICE_TZ,
        month: "short",
        day: "numeric",
      })
    : "";

const initial: BoardState = { error: null, ok: null };

/** Who the client is assigned to, changed on the row. */
function AssignedCell({
  row,
  staff,
  canEdit,
}: {
  row: ClientBoardRow;
  staff: { id: string; name: string }[];
  canEdit: boolean;
}) {
  const [state, act] = useActionState(setAssignedStaff, initial);
  if (!canEdit) {
    return <>{row.assigned_to ?? <span className="chip warn">nobody</span>}</>;
  }
  return (
    <form action={act}>
      <input type="hidden" name="client_id" value={row.client_id} />
      <select
        name="assigned_staff_id"
        aria-label={`Who is assigned to ${row.name}`}
        defaultValue={row.assigned_staff_id ?? ""}
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

/** When the next open task is due, changed on the row. */
function TaskCell({ row, today, canEdit }: { row: ClientBoardRow; today: string; canEdit: boolean }) {
  const [state, act] = useActionState(setTaskDue, { error: null, ok: null } as { error: string | null; ok: string | null });
  if (!row.next_task_id) return <span className="lock">no open task</span>;
  const late = taskOverdue(row, today);
  return (
    <>
      <div className={late ? "late" : undefined}>{row.next_task_title}</div>
      <div className="lock">
        {row.next_task_owner || "nobody"}
        {canEdit ? (
          <form action={act} style={{ display: "inline" }}>
            <input type="hidden" name="task_id" value={row.next_task_id} />
            <input
              type="date"
              name="due"
              data-col="due"
              aria-label={`When the next task for ${row.name} is due`}
              defaultValue={row.next_task_due ?? ""}
              onChange={(e) => e.currentTarget.form?.requestSubmit()}
              style={{ marginLeft: 6 }}
            />
          </form>
        ) : (
          row.next_task_due && <> · {day(row.next_task_due)}</>
        )}
      </div>
      {state.error && <div className="late">{state.error}</div>}
    </>
  );
}

function ReportPill({ row, today }: { row: ClientBoardRow; today: string }) {
  if (!row.report_status) return <span className="lock">none yet</span>;
  const late = reportOverdue(row, today);
  const cls = row.report_status === "Sent" ? "chip ok" : late ? "chip bad" : "chip warn";
  return (
    <>
      <span className={cls}>{row.report_status}</span>
      {row.report_due_on && row.report_status !== "Sent" && (
        <span className="lock"> due {day(row.report_due_on)}</span>
      )}
    </>
  );
}

export function StageBoard({
  rows,
  staff,
  today,
  canEdit,
}: {
  rows: ClientBoardRow[];
  staff: { id: string; name: string }[];
  today: string;
  canEdit: boolean;
}) {
  const [q, setQ] = useState("");
  const [office, setOffice] = useState("");
  const [assigned, setAssigned] = useState("");
  const [counselor, setCounselor] = useState("");
  const [tile, setTile] = useState<string | null>(null);
  const [sort, setSort] = useState<Sort>({ key: "", dir: 1 });
  const [shut, setShut] = useState<Set<string>>(new Set());
  const { hidden, toggle, showColumns, setShowColumns, shown } = useColumns(COLUMNS, HIDDEN_BY_DEFAULT);

  const offices = useMemo(
    () => [...new Set(rows.map((r) => r.office).filter(Boolean) as string[])].sort(),
    [rows],
  );
  const counselors = useMemo(
    () => [...new Set(rows.map((r) => r.counselor).filter(Boolean) as string[])].sort(),
    [rows],
  );
  const assignees = useMemo(
    () => [...new Set(rows.map((r) => r.assigned_to).filter(Boolean) as string[])].sort(),
    [rows],
  );

  const matching = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const chosen = TILES.find((t) => t.key === tile);
    return rows.filter((r) => {
      if (office && r.office !== office) return false;
      if (counselor && r.counselor !== counselor) return false;
      if (assigned && r.assigned_to !== assigned) return false;
      if (chosen && !chosen.holds(r, today)) return false;
      if (!needle) return true;
      return (
        r.name.toLowerCase().includes(needle) ||
        (r.goal ?? "").toLowerCase().includes(needle) ||
        (r.assigned_to ?? "").toLowerCase().includes(needle)
      );
    });
  }, [rows, q, office, counselor, assigned, tile, today]);

  const sorted = useMemo(() => {
    if (!sort.key) return matching;
    const value = (r: ClientBoardRow): string | number => {
      switch (sort.key) {
        case "client": return r.name;
        case "counselor": return r.counselor ?? "";
        case "office": return r.office ?? "";
        case "assigned": return r.assigned_to ?? "";
        case "job": return r.job_status ?? "";
        case "contact": return r.last_contact_at ?? "";
        case "task": return r.next_task_due ?? "";
        case "days": return r.days_in_stage;
        case "report": return r.report_status ?? "";
        case "attention": return r.attention_urgency ?? 99;
        case "stage": return r.stage;
        case "goal": return r.goal ?? "";
        case "services": return r.services.join(", ");
        case "billingOffice": return r.billing_office;
        case "funding": return r.funding_source ?? "";
        case "availability": return r.availability ?? "";
        case "applied": return r.applied_7d;
        case "interview": return r.next_interview ?? "";
        case "note": return r.last_note ?? "";
        default: return "";
      }
    };
    return [...matching].sort((a, b) => {
      const x = value(a);
      const y = value(b);
      const n = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y));
      return n * sort.dir;
    });
  }, [matching, sort]);

  const toggleGroup = (stage: string) =>
    setShut((s) => {
      const n = new Set(s);
      if (n.has(stage)) n.delete(stage);
      else n.add(stage);
      return n;
    });

  let rowNumber = 0;

  const cell = (r: ClientBoardRow, key: string) => {
    switch (key) {
      case "client":
        return (
          <Link href={`/clients/${r.client_id}?tab=dashboard`} style={{ fontWeight: 600 }}>
            {r.name}
          </Link>
        );
      case "counselor": return r.counselor ?? <span className="lock">not set</span>;
      case "office": return r.office ?? "";
      case "assigned": return <AssignedCell row={r} staff={staff} canEdit={canEdit} />;
      case "job":
        return r.job_status ? (
          <>
            {r.job_status}
            {r.job_status_on && <div className="lock">since {day(r.job_status_on)}</div>}
          </>
        ) : (
          <span className="lock">not started</span>
        );
      case "contact": {
        const n = daysSince(r.last_contact_at, today);
        if (n === null) return <span className="chip bad">never</span>;
        return (
          <span className={n >= OUT_OF_CONTACT ? "late" : undefined}>
            {day(r.last_contact_at)}
            <span className="lock"> {CHANNEL[r.last_contact_kind ?? ""] ?? ""}</span>
          </span>
        );
      }
      case "task": return <TaskCell row={r} today={today} canEdit={canEdit} />;
      case "days":
        return (
          <span className={r.days_in_stage >= LONG_IN_STAGE ? "late" : undefined}>{r.days_in_stage}</span>
        );
      case "report": return <ReportPill row={r} today={today} />;
      case "attention":
        return r.attention ? (
          <span className={(r.attention_urgency ?? 9) <= 3 ? "chip bad" : (r.attention_urgency ?? 9) <= 6 ? "chip warn" : "chip"}>
            {r.attention}
          </span>
        ) : (
          ""
        );
      case "stage": return stageLabel(r.stage);
      case "goal": return r.goal ?? "";
      case "services": return r.services.join(", ");
      case "billingOffice": return r.billing_office;
      case "funding": return r.funding_source ?? "";
      case "availability": return r.availability ?? "";
      case "applied": return r.applied_7d || "";
      case "interview": return r.next_interview ? day(r.next_interview) : "";
      case "note":
        return r.last_note ? (
          <>
            {r.last_note.length > 120 ? r.last_note.slice(0, 120) + "…" : r.last_note}
            {r.last_note_on && <div className="lock">{day(r.last_note_on)}</div>}
          </>
        ) : (
          ""
        );
      default: return "";
    }
  };

  return (
    <>
      {/* The tiles: five things somebody has to do something about. Clicking
          one filters every stage to it; clicking it again clears. */}
      <div className="tiles no-print">
        {TILES.map((t) => {
          const n = rows.filter((r) => t.holds(r, today)).length;
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
              <span className="tile-note">{on ? "showing these — press to clear" : "press to show these"}</span>
            </button>
          );
        })}
      </div>

      <BoardToolbar
        q={q}
        onQ={setQ}
        label="Search a client"
        placeholder="Client, goal or staff"
        right={
          <>
            <button type="button" className="btn ghost" onClick={() => setShowColumns((v) => !v)}>
              Columns
            </button>
            {canEdit && (
              <Link className="btn" href="#new-client" style={{ textDecoration: "none" }}>
                + Client
              </Link>
            )}
          </>
        }
      >
        <select aria-label="Office" value={office} onChange={(e) => setOffice(e.target.value)}>
          <option value="">Every office</option>
          {offices.map((o) => (
            <option key={o} value={o}>{o}</option>
          ))}
        </select>
        <select aria-label="Assigned staff" value={assigned} onChange={(e) => setAssigned(e.target.value)}>
          <option value="">Anybody assigned</option>
          {assignees.map((a) => (
            <option key={a} value={a}>{a}</option>
          ))}
        </select>
        <select aria-label="Counselor" value={counselor} onChange={(e) => setCounselor(e.target.value)}>
          <option value="">Every counselor</option>
          {counselors.map((c) => (
            <option key={c} value={c}>{c}</option>
          ))}
        </select>
        <span className="lock">Grouped by stage</span>
      </BoardToolbar>

      {showColumns && <ColumnsPanel columns={COLUMNS} hidden={hidden} toggle={toggle} />}

      <div className="board-wrap">
        <table className="board" data-layout="every active client, grouped by the stage they are at">
          <BoardHead columns={shown} sort={sort} onSort={(k) => setSort((s) => nextSort(s, k))} />

          {STAGES.map((stage) => {
            const inGroup = sorted.filter((r) => r.stage === stage);
            const foot = groupFooter(inGroup, today);
            const isShut = shut.has(stage);
            return (
              <tbody key={stage}>
                <tr className="group">
                  <th colSpan={shown.length + 1} scope="colgroup">
                    <div
                      className="group-bar"
                      style={{ borderLeft: `3px solid var(${stageToken(stage)})` }}
                    >
                      <button
                        type="button"
                        className="toggle"
                        aria-expanded={!isShut}
                        onClick={() => toggleGroup(stage)}
                      >
                        {isShut ? "▸" : "▾"} <span className="name">{stageLabel(stage)}</span>
                      </button>
                      <span>
                        {inGroup.length} {inGroup.length === 1 ? "client" : "clients"}
                        {inGroup.length > 0 && <> · {averageDays(inGroup)} days in stage on average</>}
                      </span>
                      <span className="lock">{stageNote(stage)}</span>
                      <span className="totals">
                        {foot.outOfContact} not contacted {OUT_OF_CONTACT}+ days · {foot.tasksOverdue} tasks
                        overdue · {foot.reportsOverdue} reports overdue
                      </span>
                    </div>
                  </th>
                </tr>

                {!isShut && inGroup.length === 0 && (
                  <tr>
                    <td className="pin-n" />
                    <td className="pin-client lock" colSpan={shown.length}>
                      Nobody at this stage
                    </td>
                  </tr>
                )}

                {!isShut &&
                  inGroup.map((r) => {
                    rowNumber += 1;
                    return (
                      <tr key={r.client_id}>
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
            ? "Nobody is on the board — add the first client."
            : "Nothing matches — clear the search, the filters or the tile."}
        </p>
      )}
    </>
  );
}
