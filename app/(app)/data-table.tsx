"use client";

import { useMemo, useState, type ReactNode } from "react";

export type DataColumn = {
  key: string;
  label: ReactNode;
  /** Numbers and money line up on the right. */
  align?: "right";
  /** On by default. Off for a column of buttons or forms. */
  sortable?: boolean;
  width?: number | string;
};

export type DataRow = {
  key: string;
  cells: Record<string, ReactNode>;
  /** What each column sorts by. A column with no value here sorts by its cell when that is plain text or a number. */
  sort?: Record<string, string | number | null | undefined>;
  /** What the filter searches. Defaults to the plain text and numbers among the cells and sort values. */
  text?: string;
};

type Sort = { key: string; dir: "asc" | "desc" } | null;

const collator = new Intl.Collator("en-US", { numeric: true, sensitivity: "base" });

function plain(node: ReactNode): string | number | null {
  if (typeof node === "string" || typeof node === "number") return node;
  return null;
}

/**
 * The one table.
 *
 * Every list of records in the CRM is drawn by this: sortable column headings,
 * a filter bar once a list is long enough to need one, a count of what is
 * showing, and a sentence - never a blank - when there is nothing to show.
 * Cells are whatever the screen passes (links, chips, forms); sorting and
 * filtering work on the plain values the screen gives alongside them.
 *
 * Rows arrive in the order the screen chose, and stay in it until somebody
 * clicks a heading.
 */
export function DataTable({
  columns,
  rows,
  empty,
  filter,
  label,
  initialSort = null,
}: {
  columns: DataColumn[];
  rows: DataRow[];
  /** The sentence shown when there are no rows at all. */
  empty: ReactNode;
  /** Show the filter bar. By default it appears for more than eight rows. */
  filter?: boolean;
  /** What the rows are, for the filter's placeholder and screen readers ("clients", "invoices"). */
  label?: string;
  initialSort?: Sort;
}) {
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<Sort>(initialSort);
  const showFilter = filter ?? rows.length > 8;

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    let list = rows;
    if (q) {
      list = rows.filter((r) => {
        const hay =
          r.text ??
          [
            ...Object.values(r.cells).map((c) => plain(c)),
            ...Object.values(r.sort ?? {}),
          ]
            .filter((v) => v !== null && v !== undefined)
            .join(" ");
        return String(hay).toLowerCase().includes(q);
      });
    }
    if (sort) {
      const value = (r: DataRow) => (r.sort && sort.key in r.sort ? r.sort[sort.key] : plain(r.cells[sort.key]));
      list = [...list].sort((a, b) => {
        const av = value(a);
        const bv = value(b);
        // Empty values go last whichever way the column is sorted.
        if (av === null || av === undefined || av === "") return bv === null || bv === undefined || bv === "" ? 0 : 1;
        if (bv === null || bv === undefined || bv === "") return -1;
        const c = typeof av === "number" && typeof bv === "number" ? av - bv : collator.compare(String(av), String(bv));
        return sort.dir === "asc" ? c : -c;
      });
    }
    return list;
  }, [rows, query, sort]);

  function toggle(key: string) {
    setSort((s) => (!s || s.key !== key ? { key, dir: "asc" } : s.dir === "asc" ? { key, dir: "desc" } : null));
  }

  return (
    <div className="data-table">
      {showFilter && (
        <div className="filter-bar no-print">
          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={`Filter ${label ?? "this list"}…`}
            aria-label={`Filter ${label ?? "this list"}`}
          />
          <span className="lock">
            {shown.length === rows.length ? `${rows.length} ${label ?? "rows"}` : `${shown.length} of ${rows.length}`}
          </span>
        </div>
      )}
      <div className="table-wrap">
        <table className="t">
          <thead>
            <tr>
              {columns.map((c) => {
                const sortable = c.sortable !== false && rows.length > 1;
                const active = sort?.key === c.key;
                return (
                  <th
                    key={c.key}
                    className={c.align === "right" ? "num" : undefined}
                    style={c.width !== undefined ? { width: c.width } : undefined}
                    aria-sort={active ? (sort!.dir === "asc" ? "ascending" : "descending") : undefined}
                  >
                    {sortable ? (
                      <button type="button" className="sort" onClick={() => toggle(c.key)}>
                        {c.label}
                        <span aria-hidden="true">{active ? (sort!.dir === "asc" ? " ↑" : " ↓") : ""}</span>
                      </button>
                    ) : (
                      c.label
                    )}
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td colSpan={columns.length} className="empty">
                  {empty}
                </td>
              </tr>
            )}
            {rows.length > 0 && shown.length === 0 && (
              <tr>
                <td colSpan={columns.length} className="empty">
                  Nothing matches &ldquo;{query}&rdquo;.
                </td>
              </tr>
            )}
            {shown.map((r) => (
              <tr key={r.key}>
                {columns.map((c) => (
                  <td key={c.key} className={c.align === "right" ? "num" : undefined}>
                    {r.cells[c.key]}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
