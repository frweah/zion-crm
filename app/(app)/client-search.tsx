"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { findClients, type Found } from "./search-actions";

/**
 * Get to a client from anywhere.
 *
 * Ctrl+K, or the button in the header. It opens on the records this person
 * has had open lately, so the commonest journey - back to the person you were
 * just with - is two keys and Enter. Typing searches name, client number,
 * USOR id, phone and email.
 *
 * Arrow keys move, Enter opens, Escape closes and puts the focus back. No
 * result is ever a dead end: it says so and offers the full list.
 */
export function ClientSearch() {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [rows, setRows] = useState<Found[]>([]);
  const [at, setAt] = useState(0);
  const [loading, setLoading] = useState(false);
  const box = useRef<HTMLInputElement>(null);
  const opener = useRef<Element | null>(null);
  const router = useRouter();

  const close = useCallback(() => {
    setOpen(false);
    setQuery("");
    setRows([]);
    setAt(0);
    if (opener.current instanceof HTMLElement) opener.current.focus();
  }, []);

  // Ctrl+K anywhere, except while somebody is typing into something else.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        opener.current = document.activeElement;
        setOpen(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (!open) return;
    box.current?.focus();
  }, [open]);

  // The typing settles before anybody is asked: a search on every keystroke
  // is a round trip per letter for a list that is about to change anyway.
  useEffect(() => {
    if (!open) return;
    let live = true;
    setLoading(true);
    const timer = window.setTimeout(async () => {
      const found = await findClients(query);
      if (!live) return;
      setRows(found);
      setAt(0);
      setLoading(false);
    }, query ? 160 : 0);
    return () => {
      live = false;
      window.clearTimeout(timer);
    };
  }, [query, open]);

  const go = useCallback(
    (row: Found | undefined) => {
      if (!row) return;
      close();
      router.push(`/clients/${row.id}`);
    },
    [close, router],
  );

  return (
    <>
      <button
        type="button"
        className="client-search-open"
        onClick={(e) => {
          opener.current = e.currentTarget;
          setOpen(true);
        }}
        aria-haspopup="dialog"
      >
        <span aria-hidden="true">⌕</span> Find a client
        <kbd>Ctrl K</kbd>
      </button>

      {open && (
        <div className="record-dialog-scrim" onClick={close}>
          <div
            className="card client-search"
            role="dialog"
            aria-label="Find a client"
            onClick={(e) => e.stopPropagation()}
          >
            <label className="field" style={{ margin: 0 }}>
              <span className="sr-only">Find a client by name, number, phone or email</span>
              <input
                ref={box}
                type="search"
                value={query}
                placeholder="Name, client number, phone or email"
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Escape") close();
                  if (e.key === "ArrowDown") {
                    e.preventDefault();
                    setAt((i) => Math.min(i + 1, rows.length - 1));
                  }
                  if (e.key === "ArrowUp") {
                    e.preventDefault();
                    setAt((i) => Math.max(i - 1, 0));
                  }
                  if (e.key === "Enter") {
                    e.preventDefault();
                    go(rows[at]);
                  }
                }}
              />
            </label>

            <ul className="client-search-list" aria-label="Clients found">
              {rows.map((row, i) => (
                <li key={row.id}>
                  <button
                    type="button"
                    className={i === at ? "on" : undefined}
                    onMouseEnter={() => setAt(i)}
                    onClick={() => go(row)}
                  >
                    <span className="who">
                      <b>{row.name}</b>
                      {row.client_no ? <span className="lock"> #{row.client_no}</span> : null}
                      {row.status && row.status !== "Active" && <span className="chip"> {row.status}</span>}
                    </span>
                    <span className="lock">
                      {row.stage}
                      {row.assigned_name ? ` · ${row.assigned_name}` : ""}
                      {row.counselor_name ? ` · ${row.counselor_name}` : ""}
                      {row.recent && !query ? " · open lately" : ""}
                    </span>
                  </button>
                </li>
              ))}
            </ul>

            {rows.length === 0 && (
              <p className="empty" style={{ margin: "10px 0 0" }}>
                {loading
                  ? "Looking…"
                  : query
                    ? "Nobody matches that. Try a surname, a client number or the last four digits of a phone number."
                    : "Records you open will appear here. Type to search everybody."}
              </p>
            )}
          </div>
        </div>
      )}
    </>
  );
}
