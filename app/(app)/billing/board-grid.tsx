"use client";

import { useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useActionState } from "react";
import { money, PRACTICE_TZ } from "@/lib/constants";
import { authorizationNumberLabel } from "@/lib/billing";
import { BOARD_GROUPS, COLLAPSED_GROUPS, type BoardClient, type BoardGroup } from "@/lib/billing-board-shape";
import { setSubmittedOn, setPaidOn, setBoardStatus, type CellState } from "./board-actions";
import { BulkClear } from "./worklist-table";

/**
 * Billing › Authorizations, as a board (owner, 17 November 2026).
 *
 * One row per client, in the group of its most pressing authorization, with
 * the client's authorizations opening underneath. It reads like a
 * spreadsheet on purpose - gridlines, a header that stays, the client column
 * pinned, row numbers, figures that line up - because the question it answers
 * is "who owes us what", and that is a question about a column of money.
 *
 * What it is not is a second place to edit an authorization. Three cells take
 * input and each calls the same database function the authorization record
 * calls (see board-actions.ts); everything else is read.
 */

const EMPTY: CellState = { error: null, ok: null };

/** The bar colour for each group, from the status colours used everywhere. */
const GROUP_CLASS: Record<BoardGroup, string> = {
  "Needs invoice": "group-needs-invoice",
  "Too late to bill": "group-too-late",
  "Waiting on payment": "group-waiting-payment",
  "Waiting for service": "group-waiting-service",
  Paid: "group-paid",
  Closed: "group-closed",
};

/** What a group is for, in one line, under its name. */
const GROUP_MEANS: Record<BoardGroup, string> = {
  "Needs invoice": "the service was delivered and no invoice has gone out",
  "Too late to bill": "past the grace, so it can only be closed",
  "Waiting on payment": "invoiced and not yet paid",
  "Waiting for service": "authorized, the work has not happened yet",
  Paid: "settled",
  Closed: "ended without being billed",
};

type Column = { key: string; label: string; num?: boolean };

const COLUMNS: Column[] = [
  { key: "client", label: "Client / Authorization" },
  { key: "office", label: "Office / Service" },
  { key: "counselor", label: "Counselor / Invoice #" },
  { key: "period", label: "Authorizations / Period" },
  { key: "received", label: "Received" },
  { key: "authorized", label: "Authorized", num: true },
  { key: "billed", label: "Billed", num: true },
  { key: "outstanding", label: "Outstanding", num: true },
  { key: "submitted", label: "Submitted on" },
  { key: "paid", label: "Paid on" },
  { key: "billby", label: "Bill by" },
  { key: "status", label: "Status" },
  { key: "next", label: "Next step" },
];

const monthOf = (period: string | null) =>
  period
    ? new Date(`${period}T00:00:00`).toLocaleDateString("en-US", {
        // The practice's zone, named, so a period reads the same wherever the
        // server happens to be (check-times).
        timeZone: PRACTICE_TZ,
        month: "short",
        year: "numeric",
      })
    : "";

/** The chip class for an attention sentence, the same scale the worklist uses. */
const urgencyClass = (u: number) => (u <= 3 ? "chip bad" : u <= 6 ? "chip warn" : "chip");

export function BoardGrid({
  clients,
  canBill,
  canExport,
  today,
  compact = false,
}: {
  clients: BoardClient[];
  canBill: boolean;
  canExport: boolean;
  today: string;
  /**
   * The same grid on one client's record (client dashboard brief, Part 3:
   * one component, not a second grid). It loses the toolbar - searching a
   * board of one is nothing to offer - and it opens: the authorizations are
   * what the card is for, and a settled one still has to be readable, so
   * Paid and Closed do not start shut either.
   */
  compact?: boolean;
}) {
  const [open, setOpen] = useState<Set<string>>(
    () => new Set(compact ? clients.map((c) => c.client_id) : []),
  );
  const [shut, setShut] = useState<Set<string>>(new Set(compact ? [] : COLLAPSED_GROUPS));
  const [q, setQ] = useState("");
  const [office, setOffice] = useState("");
  const [counselor, setCounselor] = useState("");
  const [period, setPeriod] = useState("");
  const [sort, setSort] = useState<{ key: string; dir: 1 | -1 }>({ key: "", dir: 1 });
  const [hidden, setHidden] = useState<Set<string>>(new Set());
  const [showColumns, setShowColumns] = useState(false);
  const [chosen, setChosen] = useState<string[]>([]);
  const grid = useRef<HTMLTableElement>(null);

  const offices = useMemo(
    () => [...new Set(clients.map((c) => c.office).filter(Boolean) as string[])].sort(),
    [clients],
  );
  const counselors = useMemo(
    () => [...new Set(clients.map((c) => c.counselor_name).filter(Boolean) as string[])].sort(),
    [clients],
  );
  const periods = useMemo(
    () =>
      [...new Set(clients.flatMap((c) => c.rows.map((r) => r.period).filter(Boolean) as string[]))]
        .sort()
        .reverse(),
    [clients],
  );

  const shownColumns = COLUMNS.filter((c) => !hidden.has(c.key));

  const matching = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return clients.filter((c) => {
      if (office && c.office !== office) return false;
      if (counselor && c.counselor_name !== counselor) return false;
      if (period && !c.rows.some((r) => r.period === period)) return false;
      if (!needle) return true;
      return (
        c.client_name.toLowerCase().includes(needle) ||
        c.rows.some((r) => r.number.toLowerCase().includes(needle))
      );
    });
  }, [clients, q, office, counselor, period]);

  const sorted = useMemo(() => {
    if (!sort.key) return matching;
    const value = (c: BoardClient): string | number => {
      switch (sort.key) {
        case "client": return c.client_name;
        case "office": return c.office ?? "";
        case "counselor": return c.counselor_name ?? "";
        case "period": return c.rows.length;
        case "authorized": return c.authorized;
        case "billed": return c.billed;
        case "outstanding": return c.outstanding;
        case "submitted": return c.submitted_on ?? "";
        case "paid": return c.paid_on ?? "";
        case "billby": return c.bill_by ?? "";
        case "status": return c.grp_rank;
        case "next": return c.urgency;
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

  /**
   * Up and down move between the cells of one column, the way they do in a
   * spreadsheet. Left and right are left to the text cursor inside the date,
   * which is what a person typing a date expects them to do.
   */
  const arrows = (e: React.KeyboardEvent<HTMLInputElement>, col: string) => {
    if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
    const all = [...(grid.current?.querySelectorAll<HTMLInputElement>(`input[data-col="${col}"]`) ?? [])];
    const here = all.indexOf(e.currentTarget);
    const next = all[here + (e.key === "ArrowDown" ? 1 : -1)];
    if (next) {
      e.preventDefault();
      next.focus();
      next.select?.();
    }
  };

  const toggleGroup = (g: BoardGroup) =>
    setShut((s) => {
      const n = new Set(s);
      if (n.has(g)) n.delete(g);
      else n.add(g);
      return n;
    });

  const toggleClient = (id: string) =>
    setOpen((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });

  let rowNumber = 0;

  return (
    <>
      {!compact && (
      <div className="board-toolbar no-print">
        <input
          type="search"
          aria-label="Search a client or an authorization number"
          placeholder="Client or V-number"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
        <select aria-label="Office" value={office} onChange={(e) => setOffice(e.target.value)}>
          <option value="">Every office</option>
          {offices.map((o) => (
            <option key={o} value={o}>{o}</option>
          ))}
        </select>
        <select aria-label="Counselor" value={counselor} onChange={(e) => setCounselor(e.target.value)}>
          <option value="">Every counselor</option>
          {counselors.map((k) => (
            <option key={k} value={k}>{k}</option>
          ))}
        </select>
        <select aria-label="Period" value={period} onChange={(e) => setPeriod(e.target.value)}>
          <option value="">Every period</option>
          {periods.map((p) => (
            <option key={p} value={p}>{monthOf(p)}</option>
          ))}
        </select>
        <span className="lock">Grouped by status</span>
        <div className="right">
          <button type="button" className="btn ghost" onClick={() => setShowColumns((v) => !v)}>
            Columns
          </button>
          {canExport && (
            <Link className="btn ghost" href="/insights/money#export" style={{ textDecoration: "none" }}>
              Export
            </Link>
          )}
          {canBill && (
            <Link className="btn" href="#new-authorization" style={{ textDecoration: "none" }}>
              + Authorization
            </Link>
          )}
        </div>
      </div>
      )}

      {showColumns && (
        <div className="board-columns no-print">
          {COLUMNS.map((c) => (
            <label key={c.key}>
              <input
                type="checkbox"
                checked={!hidden.has(c.key)}
                onChange={() =>
                  setHidden((s) => {
                    const n = new Set(s);
                    if (n.has(c.key)) n.delete(c.key);
                    else n.add(c.key);
                    return n;
                  })
                }
              />
              {c.label}
            </label>
          ))}
        </div>
      )}

      {canBill && chosen.length > 0 && (
        <BulkClear chosen={chosen} clear={() => setChosen([])} today={today} />
      )}

      <div className="board-wrap">
        <table className="board" ref={grid} data-layout="every client, grouped by what is owed, with their authorizations underneath">
          <thead>
            <tr>
              <th className="pin-n" scope="col">#</th>
              {shownColumns.map((c, i) => (
                <th
                  key={c.key}
                  scope="col"
                  className={[i === 0 ? "pin-client" : "", c.num ? "num" : ""].filter(Boolean).join(" ")}
                  aria-sort={sort.key === c.key ? (sort.dir === 1 ? "ascending" : "descending") : undefined}
                >
                  <button
                    type="button"
                    className="sort"
                    onClick={() =>
                      setSort((s) => ({ key: c.key, dir: s.key === c.key && s.dir === 1 ? -1 : 1 }))
                    }
                  >
                    {c.label}
                  </button>
                </th>
              ))}
            </tr>
          </thead>

          {BOARD_GROUPS.map((g) => {
            const inGroup = sorted.filter((c) => c.grp === g);
            const totals = {
              authorized: inGroup.reduce((n, c) => n + c.authorized, 0),
              billed: inGroup.reduce((n, c) => n + c.billed, 0),
              outstanding: inGroup.reduce((n, c) => n + c.outstanding, 0),
              authorizations: inGroup.reduce((n, c) => n + c.rows.length, 0),
            };
            const isShut = shut.has(g);
            return (
              <tbody key={g}>
                <tr className="group">
                  <th colSpan={shownColumns.length + 1} scope="colgroup">
                    <div className={`group-bar ${GROUP_CLASS[g]}`}>
                      <button
                        type="button"
                        className="toggle"
                        aria-expanded={!isShut}
                        onClick={() => toggleGroup(g)}
                      >
                        {isShut ? "▸" : "▾"} <span className="name">{g}</span>
                      </button>
                      {/*
                        "between them", because the board is one row per
                        client and a client brings every authorization they
                        have into the group their most pressing one puts them
                        in. Without those two words the bar read "3 clients ·
                        13 authorizations" over a group holding three.
                      */}
                      <span>
                        {inGroup.length} {inGroup.length === 1 ? "client" : "clients"} ·{" "}
                        {totals.authorizations}{" "}
                        {totals.authorizations === 1 ? "authorization" : "authorizations"} between them
                      </span>
                      <span className="lock">{GROUP_MEANS[g]}</span>
                      <span className="totals">
                        {money(totals.authorized)} authorized · {money(totals.billed)} billed ·{" "}
                        <b>{money(totals.outstanding)} outstanding</b>
                      </span>
                    </div>
                  </th>
                </tr>

                {!isShut && inGroup.length === 0 && (
                  <tr>
                    <td className="pin-n" />
                    <td className="pin-client lock" colSpan={shownColumns.length}>
                      Nothing in this group
                    </td>
                  </tr>
                )}

                {!isShut &&
                  inGroup.map((c) => {
                    rowNumber += 1;
                    const isOpen = open.has(c.client_id);
                    return (
                      <ClientRows
                        key={c.client_id}
                        n={rowNumber}
                        client={c}
                        columns={shownColumns}
                        isOpen={isOpen}
                        onToggle={() => toggleClient(c.client_id)}
                        canBill={canBill}
                        chosen={chosen}
                        setChosen={setChosen}
                        arrows={arrows}
                      />
                    );
                  })}
              </tbody>
            );
          })}
        </table>
      </div>
    </>
  );
}

function ClientRows({
  n,
  client,
  columns,
  isOpen,
  onToggle,
  canBill,
  chosen,
  setChosen,
  arrows,
}: {
  n: number;
  client: BoardClient;
  columns: Column[];
  isOpen: boolean;
  onToggle: () => void;
  canBill: boolean;
  chosen: string[];
  setChosen: (f: (c: string[]) => string[]) => void;
  arrows: (e: React.KeyboardEvent<HTMLInputElement>, col: string) => void;
}) {
  const cell = (key: string) => {
    switch (key) {
      case "client":
        return (
          <>
            <button type="button" className="row-toggle" aria-expanded={isOpen} onClick={onToggle}>
              {isOpen ? "▾" : "▸"}
            </button>
            <Link href={`/clients/${client.client_id}`} style={{ color: "var(--teal)", fontWeight: 600 }}>
              {client.client_name}
            </Link>
          </>
        );
      case "office": return client.office ?? <span className="lock">—</span>;
      case "counselor": return client.counselor_name ?? <span className="lock">—</span>;
      case "period":
        return (
          <span className="lock">
            {client.rows.length} {client.rows.length === 1 ? "authorization" : "authorizations"}
          </span>
        );
      case "received": return <span className="lock">—</span>;
      case "authorized": return money(client.authorized);
      case "billed": return money(client.billed);
      case "outstanding": return money(client.outstanding);
      case "submitted": return client.submitted_on ?? <span className="lock">—</span>;
      case "paid": return client.paid_on ?? <span className="lock">—</span>;
      case "billby": return client.bill_by ?? <span className="lock">—</span>;
      case "status": return <span className="chip">{client.grp}</span>;
      case "next":
        return client.attention ? (
          <span className={urgencyClass(client.urgency)}>{client.attention}</span>
        ) : (
          <span className="lock">nothing waiting</span>
        );
      default: return null;
    }
  };

  return (
    <>
      <tr>
        <td className="pin-n">{n}</td>
        {columns.map((c, i) => (
          <td
            key={c.key}
            className={[i === 0 ? "pin-client" : "", c.num ? "num" : ""].filter(Boolean).join(" ")}
          >
            {cell(c.key)}
          </td>
        ))}
      </tr>
      {isOpen &&
        client.rows.map((r) => (
          <SubRow
            key={r.auth_id}
            row={r}
            columns={columns}
            canBill={canBill}
            chosen={chosen}
            setChosen={setChosen}
            arrows={arrows}
          />
        ))}
    </>
  );
}

function SubRow({
  row,
  columns,
  canBill,
  chosen,
  setChosen,
  arrows,
}: {
  row: import("@/lib/billing-board-shape").BoardAuthorization;
  columns: Column[];
  canBill: boolean;
  chosen: string[];
  setChosen: (f: (c: string[]) => string[]) => void;
  arrows: (e: React.KeyboardEvent<HTMLInputElement>, col: string) => void;
}) {
  const cell = (key: string) => {
    switch (key) {
      case "client":
        return (
          <>
            {canBill && (
              <input
                type="checkbox"
                aria-label={`Choose ${row.number}`}
                checked={chosen.includes(row.auth_id)}
                onChange={() =>
                  setChosen((c) =>
                    c.includes(row.auth_id) ? c.filter((x) => x !== row.auth_id) : [...c, row.auth_id],
                  )
                }
                style={{ marginRight: 6 }}
              />
            )}
            <Link href={`/billing/authorizations/${row.auth_id}`} style={{ color: "var(--teal)" }}>
              {/* What an unnumbered authorization is called is said in one
                  place, lib/billing.ts, and this asks it rather than
                  inventing a dash of its own (check-auth-number-display). */}
              {authorizationNumberLabel(row)}
            </Link>
          </>
        );
      case "office": return row.service_type;
      case "counselor":
        return row.invoice_number ? (
          <>
            {row.invoice_number}
            {row.invoice_count > 1 && <span className="lock"> +{row.invoice_count - 1}</span>}
          </>
        ) : (
          <span className="lock">—</span>
        );
      case "period": return monthOf(row.period) || <span className="lock">—</span>;
      case "received": return row.received_on ?? <span className="lock">—</span>;
      case "authorized": return money(row.authorized);
      case "billed":
        return (
          <>
            {money(row.invoiced)}
            {row.basis === "Authorized" && <span className="board-why">no work logged yet</span>}
          </>
        );
      case "outstanding": return money(row.outstanding);
      case "submitted": return <SubmittedCell row={row} canBill={canBill} arrows={arrows} />;
      case "paid": return <PaidCell row={row} canBill={canBill} arrows={arrows} />;
      case "billby": return row.bill_by ?? <span className="lock">—</span>;
      case "status": return <StatusPill row={row} canBill={canBill} />;
      case "next":
        return row.attention ? (
          <span className={urgencyClass(row.urgency)}>{row.attention}</span>
        ) : (
          <span className="lock">nothing waiting</span>
        );
      default: return null;
    }
  };

  return (
    <tr className="sub">
      <td className="pin-n lock">↳</td>
      {columns.map((c, i) => (
        <td
          key={c.key}
          className={[i === 0 ? "pin-client" : "", c.num ? "num" : ""].filter(Boolean).join(" ")}
        >
          {cell(c.key)}
        </td>
      ))}
    </tr>
  );
}

/** The day the packet went. Refused until an invoice number exists. */
function SubmittedCell({
  row,
  canBill,
  arrows,
}: {
  row: import("@/lib/billing-board-shape").BoardAuthorization;
  canBill: boolean;
  arrows: (e: React.KeyboardEvent<HTMLInputElement>, col: string) => void;
}) {
  const [state, action] = useActionState(setSubmittedOn, EMPTY);
  if (!canBill) return <>{row.submitted_on ?? <span className="lock">—</span>}</>;
  if (!row.invoice_number) {
    return (
      <>
        <span className="lock">{row.submitted_on ?? "—"}</span>
        <span className="board-why">Raise invoice first</span>
      </>
    );
  }
  return (
    <form action={action}>
      <input type="hidden" name="auth_id" value={row.auth_id} />
      <input type="hidden" name="client_id" value={row.client_id} />
      <input
        className="board-cell"
        type="date"
        name="day"
        data-col="submitted"
        defaultValue={row.submitted_on ?? ""}
        aria-label={`Submitted on for ${row.number}`}
        onKeyDown={(e) => arrows(e, "submitted")}
        onBlur={(e) => e.currentTarget.form?.requestSubmit()}
      />
      {state.error && <span className="board-why">{state.error}</span>}
    </form>
  );
}

/**
 * The day the money arrived, which records a payment.
 *
 * The amount is what was invoiced and is shown before the click, because the
 * cell is not a date field - it settles an authorization.
 */
function PaidCell({
  row,
  canBill,
  arrows,
}: {
  row: import("@/lib/billing-board-shape").BoardAuthorization;
  canBill: boolean;
  arrows: (e: React.KeyboardEvent<HTMLInputElement>, col: string) => void;
}) {
  const [state, action] = useActionState(setPaidOn, EMPTY);
  const amount = row.invoiced > 0 ? row.invoiced : row.authorized;

  if (!canBill || row.status === "Paid" || row.status === "Closed") {
    return <>{row.paid_on ?? <span className="lock">—</span>}</>;
  }
  return (
    <form
      action={action}
      onSubmit={(e) => {
        if (!confirm(`Record ${money(amount)} received on this authorization?`)) e.preventDefault();
      }}
    >
      <input type="hidden" name="auth_id" value={row.auth_id} />
      <input type="hidden" name="client_id" value={row.client_id} />
      <input type="hidden" name="amount" value={amount.toFixed(2)} />
      <input
        className="board-cell"
        type="date"
        name="day"
        data-col="paid"
        defaultValue={row.paid_on ?? ""}
        aria-label={`Paid on for ${row.number}`}
        onKeyDown={(e) => arrows(e, "paid")}
        onBlur={(e) => {
          if (e.currentTarget.value) e.currentTarget.form?.requestSubmit();
        }}
      />
      <span className="board-why">records {money(amount)}</span>
      {state.error && <span className="board-why">{state.error}</span>}
    </form>
  );
}

/** Outstanding or Waiting on payment. Nothing else is set from here. */
function StatusPill({
  row,
  canBill,
}: {
  row: import("@/lib/billing-board-shape").BoardAuthorization;
  canBill: boolean;
}) {
  const [state, action] = useActionState(setBoardStatus, EMPTY);
  const [menu, setMenu] = useState(false);
  const tone = row.status === "Paid" ? "chip ok" : row.status === "Closed" ? "chip" : "chip warn";

  if (!canBill || row.status === "Paid" || row.status === "Closed") {
    return <span className={tone}>{row.status}</span>;
  }
  return (
    <span className="pill-menu">
      <button type="button" className={tone} aria-expanded={menu} onClick={() => setMenu((v) => !v)}>
        {row.status}
      </button>
      {menu && (
        <span className="menu">
          <form action={action} onSubmit={() => setMenu(false)}>
            <input type="hidden" name="auth_id" value={row.auth_id} />
            <input type="hidden" name="client_id" value={row.client_id} />
            <button type="submit" name="status" value="Due">Outstanding</button>
          </form>
          <form action={action} onSubmit={() => setMenu(false)}>
            <input type="hidden" name="auth_id" value={row.auth_id} />
            <input type="hidden" name="client_id" value={row.client_id} />
            <button type="submit" name="status" value="Submitted">Waiting on payment</button>
          </form>
          <p>Paid is reached by recording what arrived or by a matched warrant. Closed is on the record.</p>
          {state.error && <p>{state.error}</p>}
        </span>
      )}
    </span>
  );
}
