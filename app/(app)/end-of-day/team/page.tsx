import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PageHead } from "../../page-head";
import { DataTable, type DataRow } from "../../data-table";

/**
 * The team's days, by person.
 *
 * Under HR rather than beside the form a person fills in: one is a thing you
 * do and the other is a thing you read about other people, and the owner
 * asked for them to be in different places (18 Oct 2026).
 *
 * Who sees what is the database's decision and not this screen's. The RLS on
 * staff_days gives an Admin everybody's and a manager their own people's, so
 * the query below is the same for both and neither can be shown a row the
 * other should have had.
 */
const SINCE_DAYS = 30;

export default async function EndOfDayTeamPage({
  searchParams,
}: {
  searchParams: Promise<{ page?: string }>;
}) {
  const me = await requireStaff();
  const { page: rawPage } = await searchParams;
  const page = Math.max(0, Number(rawPage ?? 0) || 0);
  const PAGE = 50;

  const supabase = await createClient();
  const since = new Date(Date.now() - SINCE_DAYS * 86400000).toISOString().slice(0, 10);

  const [{ data: days }, { data: staff }] = await Promise.all([
    supabase
      .from("staff_days")
      .select("id, staff_id, day, submitted_at")
      .gte("day", since)
      .order("day", { ascending: false })
      .range(page * PAGE, page * PAGE + PAGE - 1),
    supabase.from("staff").select("id, name").eq("is_system", false),
  ]);

  const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));

  const rows: DataRow[] = (days ?? []).map((d) => ({
    key: d.id,
    text: `${staffName.get(d.staff_id) ?? ""} ${d.day}`,
    sort: { day: d.day, who: staffName.get(d.staff_id) ?? "", state: d.submitted_at ?? "" },
    cells: {
      day: (
        <Link href={`/end-of-day?day=${d.day}&who=${d.staff_id}`}>
          {new Date(`${d.day}T00:00:00`).toLocaleDateString("en-US", {
            month: "short",
            day: "numeric",
          })}
        </Link>
      ),
      who: staffName.get(d.staff_id) ?? "—",
      state: d.submitted_at ? "Submitted" : "Open",
    },
  }));

  return (
    <>
      <PageHead
        title="End of day — team"
        context={
          me.role === "Admin"
            ? `Everybody's days, the last ${SINCE_DAYS} days`
            : `The days of the people who report to you, the last ${SINCE_DAYS} days`
        }
      />

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="days"
          columns={[
            { key: "day", label: "Day" },
            { key: "who", label: "Who" },
            { key: "state", label: "" },
          ]}
          rows={rows}
          pageSize={PAGE}
          empty="No days yet. They appear here as people submit them."
        />
      </div>

      {(page > 0 || rows.length === PAGE) && (
        <nav className="pager no-print" aria-label="Pages of days">
          {page > 0 && <Link href={`/end-of-day/team?page=${page - 1}`}>Newer</Link>}
          {rows.length === PAGE && <Link href={`/end-of-day/team?page=${page + 1}`}>Older</Link>}
        </nav>
      )}
    </>
  );
}
