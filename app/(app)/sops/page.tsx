import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { SopEditor, NewSop, type Sop } from "./sop-editor";
import { KnowledgeShelves } from "./knowledge-shelves";
import { PageHead } from "../page-head";

export default async function SopsPage({
  searchParams,
}: {
  searchParams: Promise<{ id?: string }>;
}) {
  const me = await requireStaff();
  const { id } = await searchParams;
  const supabase = await createClient();
  const isAdmin = me.role === "Admin";

  // Row-level security already limits this to the procedures for this role,
  // so there is nothing to filter here.
  const { data } = await supabase
    .from("sops")
    .select("id, title, body, roles, screen, category, form_key")
    .order("category")
    .order("sort_order")
    .order("title");

  const sops = (data ?? []) as Sop[];
  const selected = sops.find((s) => s.id === id) ?? sops[0] ?? null;

  return (
    <>
      <PageHead
        title="Knowledge base"
        context={
          isAdmin
            ? "How the practice does things. Everyone sees their own role's articles; you can edit them here."
            : "How the practice does things"
        }
      />

      <div className="card" style={{ marginBottom: 14 }}>
        <h3 style={{ margin: 0 }}>
          <Link href="/sops/where">Where do I…?</Link>
        </h3>
        <p className="sub" style={{ margin: "4px 0 0" }}>
          The things people ask for most, and where each one lives. Start here if you are looking
          for a screen rather than a procedure.
        </p>
      </div>

      <KnowledgeShelves sops={sops} selectedId={selected?.id ?? null} />

      <div className="grid" style={{ gridTemplateColumns: "minmax(0, 1fr)" }}>
        <div className="card">
          {!selected ? (
            <div className="empty">Choose a procedure to read it.</div>
          ) : isAdmin ? (
            <SopEditor sop={selected} />
          ) : (
            <>
              <h3>{selected.title}</h3>
              <div style={{ fontSize: "var(--text-base)", lineHeight: 1.55, whiteSpace: "pre-wrap" }}>
                {selected.body}
              </div>
              {selected.screen && (
                <p className="sub" style={{ marginTop: 14, marginBottom: 0 }}>
                  Applies to the{" "}
                  <Link href={`/${selected.screen.toLowerCase()}`} style={{ color: "var(--teal)" }}>
                    {selected.screen}
                  </Link>{" "}
                  screen.
                </p>
              )}
            </>
          )}
        </div>
      </div>

      {isAdmin && <NewSop />}
    </>
  );
}
