"use client";

import { useState } from "react";

/**
 * The parts both boards are made of.
 *
 * Billing › Authorizations and Clients › Board are the same screen asking
 * different questions: a spreadsheet of one row per thing, grouped, with a
 * header that stays, a first column that stays, row numbers, sortable
 * headings, a search box, a few filters and a Columns menu. The brief for the
 * second one said "one component shared with the Billing board", and this is
 * what that came to mean in practice: the chrome is shared, the cells are
 * not. A grid that tried to draw both an authorization and a client would be
 * a configuration language, not a component.
 *
 * What is shared is exactly what would drift: the toolbar's shape, the
 * Columns menu, the sort control in a heading, and the pinned first two
 * columns. The CSS (.board, .board-wrap, .board-toolbar) was already shared.
 */

export type BoardColumn = { key: string; label: string; num?: boolean };

export type Sort = { key: string; dir: 1 | -1 };

/** The toolbar: search, then whatever filters this board has, then buttons. */
export function BoardToolbar({
  q,
  onQ,
  placeholder,
  label,
  children,
  right,
}: {
  q: string;
  onQ: (value: string) => void;
  placeholder: string;
  label: string;
  /** The board's own selects. */
  children?: React.ReactNode;
  right?: React.ReactNode;
}) {
  return (
    <div className="board-toolbar no-print">
      <input
        type="search"
        aria-label={label}
        placeholder={placeholder}
        value={q}
        onChange={(e) => onQ(e.target.value)}
      />
      {children}
      <div className="right">{right}</div>
    </div>
  );
}

/** Which columns are on, remembered for as long as the screen is open. */
export function useColumns(columns: BoardColumn[], hiddenByDefault: string[] = []) {
  const [hidden, setHidden] = useState<Set<string>>(new Set(hiddenByDefault));
  const [showColumns, setShowColumns] = useState(false);
  const toggle = (key: string) =>
    setHidden((s) => {
      const n = new Set(s);
      if (n.has(key)) n.delete(key);
      else n.add(key);
      return n;
    });
  return {
    hidden,
    toggle,
    showColumns,
    setShowColumns,
    shown: columns.filter((c) => !hidden.has(c.key)),
  };
}

export function ColumnsPanel({
  columns,
  hidden,
  toggle,
}: {
  columns: BoardColumn[];
  hidden: Set<string>;
  toggle: (key: string) => void;
}) {
  return (
    <div className="board-columns no-print">
      {columns.map((c) => (
        <label key={c.key}>
          <input type="checkbox" checked={!hidden.has(c.key)} onChange={() => toggle(c.key)} />
          {c.label}
        </label>
      ))}
    </div>
  );
}

/**
 * The heading row: a row number column that stays, then the columns, the
 * first of which stays too.
 */
export function BoardHead({
  columns,
  sort,
  onSort,
}: {
  columns: BoardColumn[];
  sort: Sort;
  onSort: (key: string) => void;
}) {
  return (
    <thead>
      <tr>
        <th className="pin-n" scope="col">#</th>
        {columns.map((c, i) => (
          <th
            key={c.key}
            scope="col"
            className={[i === 0 ? "pin-client" : "", c.num ? "num" : ""].filter(Boolean).join(" ")}
            aria-sort={sort.key === c.key ? (sort.dir === 1 ? "ascending" : "descending") : undefined}
          >
            <button type="button" className="sort" onClick={() => onSort(c.key)}>
              {c.label}
            </button>
          </th>
        ))}
      </tr>
    </thead>
  );
}

/** Clicking a heading sorts by it, and clicking it again turns it round. */
export function nextSort(sort: Sort, key: string): Sort {
  return { key, dir: sort.key === key && sort.dir === 1 ? -1 : 1 };
}
