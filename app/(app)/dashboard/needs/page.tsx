import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { NEEDS, loadNeed, countNeeds, type NeedKey } from "@/lib/needs";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";

/**
 * The list behind a dashboard counter.
 *
 * Counter and list come from the same function, so a number can never disagree
 * with what it opens — which is how this sort of dashboard usually goes wrong,
 * and how it stops being believed.
 *
 * The five lists are a choice of what to show on one screen, not five screens,
 * so they are a segmented choice rather than tabs.
 */
export default async function NeedsPage({
  searchParams,
}: {
  searchParams: Promise<{ list?: string }>;
}) {
  const me = await requireStaff();
  const supabase = await createClient();

  const params = await searchParams;
  const key = (NEEDS.find((n) => n.key === params.list)?.key ?? "tasks") as NeedKey;

  const [rows, counts] = await Promise.all([
    loadNeed(supabase, key, me),
    countNeeds(supabase, me),
  ]);

  const active = NEEDS.find((n) => n.key === key)!;

  const explain: Record<NeedKey, string> = {
    tasks: "Open tasks due today or already past.",
    interviews: "Interviews in the next seven days, from the job tracker.",
    followups: "Follow-up dates that have arrived or passed.",
    inactive:
      "Active clients with nothing recorded for thirty days — no note, call, form, appointment, logged email, job or hours.",
    paperwork:
      "Clients where hours are logged against an open authorization and a USOR form that gates the invoice is not done.",
  };

  return (
    <>
      <PageHead
        title="Needs attention"
        context={`${me.role === "Admin" ? "Across everybody." : "Yours."} ${explain[key]}`}
      />

      <div className="segmented no-print" style={{ marginBottom: 14 }}>
        {NEEDS.map((n) => (
          <Link
            key={n.key}
            href={`/dashboard/needs?list=${n.key}`}
            className={n.key === key ? "on" : undefined}
          >
            {n.label} {counts[n.key]}
          </Link>
        ))}
      </div>

      {/* Rows keep the order the list chose (soonest or quietest first) until a heading is clicked. */}
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label={active.label.toLowerCase()}
          columns={[
            { key: "item", label: "What" },
            { key: "when", label: "When", align: "right", width: 120 },
          ]}
          rows={rows.map((r) => ({
            key: `${key}-${r.id}`,
            cells: {
              item: (
                <>
                  <Link href={r.href} style={{ fontWeight: 600 }}>
                    {r.title}
                  </Link>
                  <div className="lock">{r.detail}</div>
                </>
              ),
              when: <span style={{ whiteSpace: "nowrap", color: "var(--muted)" }}>{r.when ?? ""}</span>,
            },
            sort: { item: r.title, when: r.when },
            text: `${r.title} ${r.detail} ${r.when ?? ""}`,
          }))}
          empty={`Nothing here — ${active.label.toLowerCase()} is clear.`}
        />
      </div>
    </>
  );
}
