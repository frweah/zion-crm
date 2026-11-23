"use client";

import { useMemo, useState } from "react";
import { useActionState } from "react";
import Link from "next/link";
import { PRACTICE_TZ } from "@/lib/constants";
import { lastLine } from "@/lib/text-rows";
import {
  CLOSED_GROUPS,
  GROUPS,
  TILES,
  CAN_SEND_TEXTS,
  dots,
  firstLine,
  waited,
  type ThreadRow,
} from "@/lib/threads-board-shape";
import {
  BoardHead,
  BoardToolbar,
  ColumnsPanel,
  nextSort,
  useColumns,
  type BoardColumn,
  type Sort,
} from "../../board-chrome";
import { assignThread, type ThreadState } from "./actions";
import { approveUpdate, sendUpdate, type UpdateState } from "../../messages/weekly-updates/actions";

/**
 * The client threads board (Communications brief, Part 2).
 *
 * The same chrome as the other three boards - Billing › Authorizations,
 * Clients › Board and Reports - because this is the fourth of the same screen
 * and a fourth grid with its own toolbar is how four screens stop behaving
 * alike.
 *
 * One row per client, and two kinds of row that are not clients: a Friday
 * draft waiting on somebody, with its own Approve and its own Send, and
 * whoever is not a client yet. Which group each is in is the database's
 * answer, not this screen's - `client_threads_board` decides, a verify script
 * can put a fault in it, and a board that re-derived it would be a second
 * opinion nobody asked for.
 *
 * One cell takes input: Assigned. Everything else is a link to the thread
 * beside it or to the screen that already does the work.
 */

const COLUMNS: BoardColumn[] = [
  { key: "client", label: "Client" },
  { key: "numbers", label: "Numbers" },
  { key: "via", label: "Via" },
  { key: "last", label: "Last message" },
  { key: "assigned", label: "Assigned" },
  { key: "unread", label: "Unread", num: true },
  { key: "next", label: "Next scheduled" },
  { key: "status", label: "Status" },
];

const initial: ThreadState = { error: null, ok: null };
const initialUpdate: UpdateState = { error: null, ok: null };

const stamp = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleString("en-US", {
        timeZone: PRACTICE_TZ,
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      })
    : "";

const day = (iso: string | null) =>
  iso
    ? new Date(iso.length === 10 ? `${iso}T12:00:00Z` : iso).toLocaleDateString("en-US", {
        timeZone: PRACTICE_TZ,
        month: "short",
        day: "numeric",
      })
    : "";

/** Who is answering this thread. `assign_conversation` decides who may. */
function AssignedCell({ row, staff }: { row: ThreadRow; staff: { id: string; name: string }[] }) {
  const [state, act] = useActionState(assignThread, initial);
  if (!row.conversation_id) {
    return <span className="lock">{row.assigned_name ?? "—"}</span>;
  }
  return (
    <form action={act}>
      <input type="hidden" name="conversation_id" value={row.conversation_id} />
      <input type="hidden" name="client_id" value={row.client_id ?? ""} />
      <select
        name="staff_id"
        aria-label={`Who is answering ${row.client_name ?? row.who}`}
        defaultValue={row.assigned_staff_id ?? ""}
        onChange={(e) => e.currentTarget.form?.requestSubmit()}
      >
        <option value="">Nobody</option>
        {staff.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </select>
      {state.error && <div className="bad lock">{state.error}</div>}
    </form>
  );
}

/**
 * A Friday draft, approved and sent the way it already is.
 *
 * Two clicks rather than one, and the same two functions the Friday screen
 * calls: Approve, then Send it. The owner's ruling was that this keeps its
 * existing confirm, and the existing confirm is that approving and sending
 * are separate decisions.
 */
function DraftActions({ row }: { row: ThreadRow }) {
  const [approveState, approve, approving] = useActionState(approveUpdate, initialUpdate);
  const [sendState, send, sending] = useActionState(sendUpdate, initialUpdate);
  const said = approveState.error ?? sendState.error ?? approveState.ok ?? sendState.ok;
  const blocked = !row.can_text;

  return (
    <div className="row2" style={{ gap: 6, flexWrap: "wrap" }}>
      {row.last_status === "Approved" ? (
        <>
          <form action={approve}>
            <input type="hidden" name="id" value={row.update_id ?? ""} />
            <input type="hidden" name="approved" value="no" />
            <button className="btn ghost" disabled={approving} style={{ padding: "2px 10px" }}>
              Back to a draft
            </button>
          </form>
          {!blocked && (
            <form action={send}>
              <input type="hidden" name="id" value={row.update_id ?? ""} />
              <button className="btn" disabled={sending} style={{ padding: "2px 10px" }}>
                {sending ? "Sending…" : "Send it"}
              </button>
            </form>
          )}
        </>
      ) : (
        <form action={approve}>
          <input type="hidden" name="id" value={row.update_id ?? ""} />
          <input type="hidden" name="approved" value="yes" />
          <button className="btn ghost" disabled={approving} style={{ padding: "2px 10px" }}>
            Approve
          </button>
        </form>
      )}
      {blocked && <span className="chip bad">No consent</span>}
      {said && <div className="lock">{said}</div>}
    </div>
  );
}

export function ThreadsBoard({
  rows,
  staff,
  show,
  openKey,
  role,
}: {
  rows: ThreadRow[];
  staff: { id: string; name: string }[];
  /** A tile chosen in the address, so a link can point at one. */
  show: string | null;
  openKey: string | null;
  role: string;
}) {
  const [q, setQ] = useState("");
  const [who, setWho] = useState("");
  const [tile, setTile] = useState<string | null>(
    TILES.some((t) => t.key === show) ? (show as string) : null,
  );
  const [sort, setSort] = useState<Sort>({ key: "", dir: 1 });
  const [shut, setShut] = useState<Set<string>>(new Set(CLOSED_GROUPS));
  const { hidden, toggle, showColumns, setShowColumns, shown } = useColumns(COLUMNS, []);

  const people = useMemo(
    () => [...new Set(rows.map((r) => r.assigned_name).filter(Boolean) as string[])].sort(),
    [rows],
  );

  const matching = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const chosen = TILES.find((t) => t.key === tile);
    return rows.filter((r) => {
      if (who && r.assigned_name !== who) return false;
      if (chosen && !chosen.holds(r)) return false;
      if (!needle) return true;
      return (
        (r.client_name ?? "").toLowerCase().includes(needle) ||
        r.who.toLowerCase().includes(needle) ||
        (r.last_body ?? "").toLowerCase().includes(needle) ||
        (r.assigned_name ?? "").toLowerCase().includes(needle) ||
        (r.numbers ?? []).some((n) => n.phone.includes(needle))
      );
    });
  }, [rows, q, who, tile]);

  const sorted = useMemo(() => {
    if (!sort.key) return matching;
    const value = (r: ThreadRow): string | number => {
      switch (sort.key) {
        case "client": return r.client_name ?? r.who;
        case "numbers": return (r.numbers ?? []).length;
        case "via": return (r.channels ?? []).join(" ");
        case "last": return r.last_at ?? "";
        case "assigned": return r.assigned_name ?? "";
        case "unread": return r.unread;
        case "next": return r.next_scheduled ?? r.next_update ?? "";
        case "status": return r.status;
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

  const toggleGroup = (key: string) =>
    setShut((s) => {
      const n = new Set(s);
      if (n.has(key)) n.delete(key);
      else n.add(key);
      return n;
    });

  let rowNumber = 0;

  /** Where a row opens: a client by their id, a stranger by the thread's. */
  const href = (r: ThreadRow) =>
    `/communication/threads?c=${r.kind === "client" ? r.client_id : r.conversation_id}`;

  const cell = (r: ThreadRow, key: string) => {
    switch (key) {
      case "client":
        return r.client_id ? (
          <>
            <Link href={`/clients/${r.client_id}?tab=dashboard`} style={{ fontWeight: 600 }}>
              {r.client_name}
            </Link>
            {r.kind === "draft" && <div className="lock">to {r.who}</div>}
          </>
        ) : (
          <>
            <b>{r.who}</b>
            <div className="lock">not matched to anybody</div>
          </>
        );
      case "numbers":
        if (r.kind === "stranger") return <span className="lock">—</span>;
        return (
          <span className="row2" style={{ gap: 6, flexWrap: "wrap" }}>
            {dots(r).map((d) => (
              <span key={d.number.phone} className="lock" title={d.title} style={{ whiteSpace: "nowrap" }}>
                <span aria-hidden="true" className={`dot dot-${d.tone}`} /> {d.number.phone}
                {d.number.whose === "Contact" && ` · ${d.number.whose_name}`}
              </span>
            ))}
            {(r.numbers ?? []).length === 0 && <span className="lock">no number</span>}
          </span>
        );
      case "via":
        return (
          <span className="row2" style={{ gap: 4, flexWrap: "wrap" }}>
            {(r.channels ?? []).map((c) => (
              <span key={c} className="chip">
                {c}
              </span>
            ))}
          </span>
        );
      case "last": {
        // Which way it went and who said it come from `lastLine`, the one
        // place in the practice that decides either (lib/text-rows.ts). The
        // inbox and the client's record read the same function, which is what
        // stops one text being described two ways.
        const said = lastLine(
          {
            sender_kind: r.last_sender_kind,
            sender: r.last_sender,
            body: r.last_body,
            media_url: r.last_media_url,
          },
          r.client_name ?? r.who,
        );
        return (
          <Link href={href(r)} style={{ textDecoration: "none", color: "inherit", display: "block" }}>
            <span className="chip">{said.direction}</span> <span className="lock">{said.who}</span>
            <div>{firstLine(said.words)}</div>
            <div className="lock">
              {stamp(r.last_at)}
              {r.waiting_hours !== null && ` · waiting ${waited(r.waiting_hours)}`}
            </div>
          </Link>
        );
      }
      case "assigned":
        return <AssignedCell row={r} staff={staff} />;
      case "unread":
        return r.unread > 0 ? <span className="chip gold">{r.unread}</span> : "";
      case "next":
        return r.next_scheduled ? (
          <>
            {stamp(r.next_scheduled)}
            <div className="lock">a text waiting for the window</div>
          </>
        ) : r.next_update ? (
          <>
            {day(r.next_update)}
            <div className="lock">Friday update</div>
          </>
        ) : (
          ""
        );
      case "status":
        if (r.kind === "draft") return <DraftActions row={r} />;
        return (
          <span className="row2" style={{ gap: 6, flexWrap: "wrap" }}>
            <Link
              className={
                "chip " +
                (r.grp === "needs-reply" || r.grp === "stuck"
                  ? "bad"
                  : r.grp === "quiet" || r.grp === "stranger"
                    ? "warn"
                    : "ok")
              }
              href={href(r)}
              style={{ textDecoration: "none" }}
            >
              {r.status}
            </Link>
            {r.opted_out && <span className="chip bad">STOP</span>}
            {r.kind === "client" && r.consent_missing && <span className="chip warn">No consent</span>}
          </span>
        );
      default:
        return "";
    }
  };

  return (
    <>
      <div className="tiles no-print">
        {TILES.map((t) => {
          const n = rows.filter((x) => t.holds(x)).length;
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
      </div>

      <BoardToolbar
        q={q}
        onQ={setQ}
        label="Search a thread"
        placeholder="Client, number, who said it or the words"
        right={
          <button type="button" className="btn ghost" onClick={() => setShowColumns((v) => !v)}>
            Columns
          </button>
        }
      >
        <select aria-label="Assigned" value={who} onChange={(e) => setWho(e.target.value)}>
          <option value="">Anybody</option>
          {people.map((p) => (
            <option key={p} value={p}>
              {p}
            </option>
          ))}
        </select>
        <span className="lock">
          {CAN_SEND_TEXTS.includes(role) ? "Grouped by what is owed" : "You can log a call, not send a text"}
        </span>
      </BoardToolbar>

      {showColumns && <ColumnsPanel columns={COLUMNS} hidden={hidden} toggle={toggle} />}

      <div className="board-wrap">
        <table
          className="board"
          data-layout="one row per client thread, grouped by what is owed on it"
        >
          <BoardHead columns={shown} sort={sort} onSort={(k) => setSort((s) => nextSort(s, k))} />

          {GROUPS.map((group) => {
            const inGroup = sorted.filter((r) => r.grp === group.key);
            const isShut = shut.has(group.key);
            const waitingLongest = inGroup.reduce(
              (most, r) => Math.max(most, r.waiting_hours ?? 0),
              0,
            );
            return (
              <tbody key={group.key}>
                <tr className="group">
                  <th colSpan={shown.length + 1} scope="colgroup">
                    <div className="group-bar">
                      <button
                        type="button"
                        className="toggle"
                        aria-expanded={!isShut}
                        onClick={() => toggleGroup(group.key)}
                      >
                        {isShut ? "▸" : "▾"} <span className="name">{group.label}</span>
                      </button>
                      <span>
                        {inGroup.length} {inGroup.length === 1 ? "thread" : "threads"}
                      </span>
                      <span className="totals">
                        {group.key === "needs-reply" && waitingLongest > 0
                          ? `longest ${waited(waitingLongest)}`
                          : group.key === "stuck"
                            ? `${inGroup.reduce((n, r) => n + r.failed, 0)} not delivered`
                            : ""}
                      </span>
                    </div>
                  </th>
                </tr>

                {!isShut && inGroup.length === 0 && (
                  <tr>
                    <td className="pin-n" />
                    <td className="pin-client lock" colSpan={shown.length}>
                      Nothing here
                    </td>
                  </tr>
                )}

                {!isShut &&
                  inGroup.map((r) => {
                    rowNumber += 1;
                    return (
                      <tr key={r.row_key} className={r.row_key === openKey ? "on" : undefined}>
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
            ? "Nothing yet — the first text, call or filed email puts a client here."
            : "Nothing matches — clear the search, the filter or the tile."}
        </p>
      )}
    </>
  );
}
