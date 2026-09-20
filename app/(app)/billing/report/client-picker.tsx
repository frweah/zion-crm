"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { findClients, type Found } from "../../search-actions";

/**
 * Which client is being billed for.
 *
 * The same search the rest of the CRM uses, so a name typed here finds the
 * same person it would anywhere else - and with nothing typed it offers the
 * records this person has had open lately, which on a billing morning is
 * usually the one they have just finished with.
 */
export function ClientPicker({ current }: { current?: string }) {
  const [query, setQuery] = useState("");
  const [rows, setRows] = useState<Found[]>([]);
  const [looking, setLooking] = useState(false);
  const router = useRouter();

  useEffect(() => {
    let live = true;
    setLooking(true);
    const timer = window.setTimeout(async () => {
      const found = await findClients(query);
      if (!live) return;
      setRows(found);
      setLooking(false);
    }, query ? 160 : 0);
    return () => {
      live = false;
      window.clearTimeout(timer);
    };
  }, [query]);

  return (
    <div>
      <label className="field" style={{ margin: 0 }}>
        {current ? "Bill for somebody else" : "Client"}
        <input
          type="search"
          value={query}
          placeholder={current ?? "Name, client number, phone or email"}
          onChange={(e) => setQuery(e.target.value)}
        />
      </label>

      {rows.length > 0 && (
        <ul className="client-search-list" style={{ maxHeight: "34vh" }} aria-label="Clients found">
          {rows.map((row) => (
            <li key={row.id}>
              <button type="button" onClick={() => router.push(`/billing/report?client=${row.id}`)}>
                <span className="who">
                  <b>{row.name}</b>
                  {row.client_no ? <span className="lock"> #{row.client_no}</span> : null}
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
      )}

      {rows.length === 0 && !looking && (
        <p className="lock" style={{ margin: "8px 0 0" }}>
          {query
            ? "Nobody matches that. Try a surname, a client number or the last four digits of a phone number."
            : "Records you open will appear here. Type to search everybody."}
        </p>
      )}
    </div>
  );
}
