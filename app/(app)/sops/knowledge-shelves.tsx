"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import type { Sop } from "./sop-editor";

/**
 * The knowledge base as shelves of article cards (Design language, §3).
 *
 * A list of six titles down the left was fine while there were six. What a
 * knowledge base needs is a way in for somebody who does not know what the
 * article is called: a category to browse, and a search that reads the
 * articles rather than only their titles.
 *
 * "Where do I…?" is the first shelf because it is the question people arrive
 * with - they are looking for a screen, not for a procedure.
 */
const FIRST = "Where do I…?";

export function KnowledgeShelves({ sops, selectedId }: { sops: Sop[]; selectedId: string | null }) {
  const [query, setQuery] = useState("");

  const shelves = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const matching = needle
      ? sops.filter((s) => `${s.title} ${s.body}`.toLowerCase().includes(needle))
      : sops;

    const by = new Map<string, Sop[]>();
    for (const s of matching) {
      const shelf = s.category ?? "How we work";
      if (!by.has(shelf)) by.set(shelf, []);
      by.get(shelf)!.push(s);
    }
    return [...by.entries()].sort(([a], [b]) => (a === FIRST ? -1 : b === FIRST ? 1 : a.localeCompare(b)));
  }, [sops, query]);

  const found = shelves.reduce((n, [, list]) => n + list.length, 0);

  return (
    <section className="page-section">
      <label className="field" style={{ maxWidth: 420 }}>
        Search the knowledge base
        <input
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="A word from the article, not only its title"
        />
      </label>

      {query && (
        <p className="lock" style={{ margin: "0 0 10px" }}>
          {found === 0 ? "Nothing matches that." : `${found} ${found === 1 ? "article" : "articles"}.`}
        </p>
      )}

      {shelves.map(([shelf, list]) => (
        <div key={shelf} style={{ marginBottom: 14 }}>
          <h2 className="h2">{shelf}</h2>
          <div className="hub-cards">
            {shelf === FIRST && !query && (
              <Link href="/sops/where" className="hub-card">
                <span className="hub-card-label">Where do I…?</span>
                <span className="hub-card-note">
                  The things people ask for most, and where each one lives.
                </span>
              </Link>
            )}
            {list.map((s) => (
              <Link
                key={s.id}
                href={`/sops?id=${s.id}`}
                className={"hub-card" + (selectedId === s.id ? " hub-card-on" : "")}
              >
                <span className="hub-card-label">{s.title}</span>
                <span className="hub-card-note">{s.body.slice(0, 90).trim()}…</span>
              </Link>
            ))}
          </div>
        </div>
      ))}
    </section>
  );
}
