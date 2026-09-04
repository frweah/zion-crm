import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { SopEditor, NewSop, type Sop } from "./sop-editor";

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
    .select("id, title, body, roles, screen")
    .order("sort_order")
    .order("title");

  const sops = (data ?? []) as Sop[];
  const selected = sops.find((s) => s.id === id) ?? sops[0] ?? null;

  return (
    <>
      <h1 className="h1">Standard operating procedures</h1>
      <p className="sub">
        {isAdmin
          ? "Everyone sees the procedures for their role. You can edit them here."
          : "Procedures for your role"}
      </p>

      <div className="grid" style={{ gridTemplateColumns: "minmax(200px, 1fr) minmax(0, 2fr)" }}>
        <div className="card" style={{ padding: 8, alignSelf: "start" }}>
          {sops.length === 0 && <div className="empty">No procedures for this role yet.</div>}
          {sops.map((s) => (
            <Link
              key={s.id}
              href={`/sops?id=${s.id}`}
              className={"navb" + (selected?.id === s.id ? " on" : "")}
              style={{ color: selected?.id === s.id ? "var(--forest)" : "var(--ink)" }}
            >
              {s.title}
            </Link>
          ))}
        </div>

        <div className="card">
          {!selected ? (
            <div className="empty">Choose a procedure to read it.</div>
          ) : isAdmin ? (
            <SopEditor sop={selected} />
          ) : (
            <>
              <h3>{selected.title}</h3>
              <div style={{ fontSize: 14, lineHeight: 1.55, whiteSpace: "pre-wrap" }}>
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
