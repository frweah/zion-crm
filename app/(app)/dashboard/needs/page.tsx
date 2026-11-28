import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { PRACTICE_TZ } from "@/lib/constants";
import { createClient } from "@/lib/supabase/server";
import { byKind, kindWord, kindCount, worstFirst, type NextStep } from "@/lib/next-steps";
import { RecordHeader } from "../../record-header";
import { DataTable } from "../../data-table";

/**
 * The list behind a counter.
 *
 * Counter and list come from the same call now, not merely from the same
 * function: `next_steps` is asked once and both the strip of counts and the
 * rows below are read off that one answer, so a number cannot disagree with
 * what it opens even by a second of drift.
 *
 * There is no roster of lists here any more. There were five - tasks,
 * interviews, follow-ups, inactive, paperwork - and they were a roster in
 * TypeScript with its own thresholds: thirty days of silence where the
 * threads board said fourteen, and a "follow-up" that meant a column on the
 * job tracker where the nightly alerts meant one on the contact log. The
 * strip is now one tile per kind the engine returned, so a kind added to the
 * rules appears here without anybody remembering to add it, and a kind that
 * stops firing stops being offered.
 *
 * "Mine" unless Admin, which is how tasks already work and what scope
 * 'person' and 'owner' mean.
 */
export default async function NeedsPage({
  searchParams,
}: {
  searchParams: Promise<{ list?: string }>;
}) {
  const me = await requireStaff();
  const supabase = await createClient();

  const params = await searchParams;
  const { data } = await supabase.rpc("next_steps", {
    p_scope: me.role === "Admin" ? "owner" : "person",
    p_person: me.role === "Admin" ? null : me.id,
    p_client: null,
  });
  const steps = (data ?? []) as NextStep[];
  const counts = byKind(steps);

  // The kind asked for, or the worst one there is, or nothing at all.
  const kind = counts.some((c) => c.kind === params.list) ? params.list! : (counts[0]?.kind ?? null);
  const rows = worstFirst(steps.filter((s) => s.kind === kind));

  const names = await (async () => {
    const ids = [...new Set(rows.map((r) => r.client_id).filter((v): v is string => Boolean(v)))];
    if (ids.length === 0) return new Map<string, string>();
    const { data: who } = await supabase.from("clients").select("id, name").in("id", ids);
    return new Map((who ?? []).map((c) => [c.id, c.name] as const));
  })();

  // The practice's zone, named: a date-only value read as midnight UTC shows
  // as the day before from five in the evening in Utah.
  const day = (at: string | null) =>
    at
      ? new Date(at).toLocaleDateString("en-US", {
          timeZone: PRACTICE_TZ,
          month: "short",
          day: "numeric",
        })
      : "";

  return (
    <>
      <RecordHeader
        back={{ href: "/dashboard", label: "Today" }}
        title="Needs attention"
        standing={
          `${me.role === "Admin" ? "Across everybody" : "Yours"}, worst first. ` +
          `${steps.length} ${steps.length === 1 ? "thing" : "things"} outstanding`
        }
      />

      {counts.length > 0 && (
        <div className="segmented no-print" style={{ marginBottom: 14 }}>
          {counts.map((c) => (
            <Link
              key={c.kind}
              href={`/dashboard/needs?list=${c.kind}`}
              className={c.kind === kind ? "on" : undefined}
            >
              {kindCount(c.kind, c.n)}
            </Link>
          ))}
        </div>
      )}

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label={kind ? kindWord(kind).toLowerCase() : "work"}
          columns={[
            { key: "item", label: "What" },
            { key: "who", label: "Whose", width: 160 },
            { key: "when", label: "When", align: "right", width: 120 },
          ]}
          rows={rows.map((r, i) => ({
            key: `${r.kind}-${r.client_id ?? "none"}-${i}`,
            cells: {
              item: (
                <>
                  <Link href={r.action_href} style={{ fontWeight: 600 }}>
                    {r.what}
                  </Link>
                  <div className="lock">
                    {r.client_id ? (names.get(r.client_id) ?? "a client") : "nobody's client"}
                  </div>
                </>
              ),
              who: <span className="lock">{r.who ?? "nobody"}</span>,
              when: <span style={{ whiteSpace: "nowrap", color: "var(--muted)" }}>{day(r.when)}</span>,
            },
            sort: { item: r.what, who: r.who ?? "", when: r.when ?? "" },
            text: `${r.what} ${r.who ?? ""} ${r.client_id ? (names.get(r.client_id) ?? "") : ""}`,
          }))}
          empty="Nothing outstanding — this list is clear."
        />
      </div>
    </>
  );
}
