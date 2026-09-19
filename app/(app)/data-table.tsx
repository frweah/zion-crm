"use client";

import { Fragment, useId, useMemo, useState, type ReactNode } from "react";

export type DataColumn = {
  key: string;
  label: ReactNode;
  /** Numbers and money line up on the right. */
  align?: "right";
  /** On by default. Off for a column of buttons or forms. */
  sortable?: boolean;
  /** The column's name in the Sort by choice, when its label is not plain text. */
  sortLabel?: string;
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
 *
 * On a phone the headings are off to the side of a table that scrolls, so the
 * main lists also offer the same sort as one "Sort by" choice above the rows
 * (sortBy). It is the same state as the headings - choose there or click here,
 * it is one sort.
 *
 * A long list shows fifty rows at a time (pageSize), with the pages and a
 * "Show all" beneath. Paging happens after the filter and the sort, so a
 * filter searches every row and a sort orders every row, not just this page.
 */
export function DataTable({
  columns,
  rows,
  empty,
  filter,
  label,
  initialSort = null,
  sortBy = false,
  pageSize,
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
  /** Offer a "Sort by" choice above the table, for screens too narrow to reach the headings. */
  sortBy?: boolean;
  /** Rows to a page, with "Show all" below. Unset: every row, as before. */
  pageSize?: number;
}) {
  const sortId = useId();
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<Sort>(initialSort);
  const showFilter = filter ?? rows.length > 8;
  const [page, setPage] = useState(0);
  const [all, setAll] = useState(false);

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

  // A new filter or sort starts again at the first page.
  const paged = Boolean(pageSize) && !all && shown.length > (pageSize ?? 0);
  const pages = paged ? Math.ceil(shown.length / pageSize!) : 1;
  const current = Math.min(page, pages - 1);
  const visible = paged ? shown.slice(current * pageSize!, (current + 1) * pageSize!) : shown;

  function toggle(key: string) {
    setPage(0);
    setSort((s) => (!s || s.key !== key ? { key, dir: "asc" } : s.dir === "asc" ? { key, dir: "desc" } : null));
  }

  const sortableColumns = columns.filter((c) => c.sortable !== false);
  const nameOf = (c: DataColumn) => c.sortLabel ?? (typeof c.label === "string" ? c.label : c.key);

  return (
    <div className="data-table">
      {sortBy && sortableColumns.length > 0 && rows.length > 1 && (
        <div className="sort-by no-print">
          <label htmlFor={sortId}>Sort by</label>
          <select
            id={sortId}
            value={sort ? `${sort.key}:${sort.dir}` : ""}
            onChange={(e) => {
              const [key, dir] = e.target.value.split(":");
              setSort(key ? { key, dir: dir === "desc" ? "desc" : "asc" } : null);
              setPage(0);
            }}
          >
            <option value="">As listed</option>
            {sortableColumns.map((c) => (
              <Fragment key={c.key}>
                <option value={`${c.key}:asc`}>{nameOf(c)}, ascending</option>
                <option value={`${c.key}:desc`}>{nameOf(c)}, descending</option>
              </Fragment>
            ))}
          </select>
        </div>
      )}
      {showFilter && (
        <div className="filter-bar no-print">
          <input
            type="search"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setPage(0);
            }}
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
            {visible.map((r) => (
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
      {pageSize && shown.length > pageSize && (
        <nav className="pager no-print" aria-label={`Pages of ${label ?? "rows"}`}>
          <span className="lock" aria-live="polite">
            {paged
              ? `${current * pageSize + 1}–${Math.min((current + 1) * pageSize, shown.length)} of ${shown.length}`
              : `All ${shown.length}`}
          </span>
          {paged && (
            <>
              <button type="button" className="btn ghost" disabled={current === 0} onClick={() => setPage(current - 1)}>
                Previous
              </button>
              <button
                type="button"
                className="btn ghost"
                disabled={current >= pages - 1}
                onClick={() => setPage(current + 1)}
              >
                Next
              </button>
            </>
          )}
          <button
            type="button"
            className="btn ghost"
            aria-pressed={all}
            onClick={() => {
              setAll(!all);
              setPage(0);
            }}
          >
            {all ? `Show ${pageSize} at a time` : `Show all ${shown.length}`}
          </button>
        </nav>
      )}
    </div>
  );
}
