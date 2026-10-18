import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { PageHead } from "../page-head";
import { DataTable, type DataRow } from "../data-table";
import { DayForm, type DayLine } from "./day-form";

/**
 * The end of the day.
 *
 * The practice's own EOD template, in the CRM: the same headings, the same
 * three statuses, and the same two halves — the tasks and the bottlenecks.
 * What it adds is that a line about a client lands on that client's record,
 * that what was unfinished yesterday is already here, and that submitting it
 * is a thing that happens once.
 *
 * Everybody has one. Admin can read anybody's, and a manager their own
 * people's, through the same screen with ?who=.
 */
export default async function EndOfDayPage({
  searchParams,
}: {
  searchParams: Promise<{ day?: string; who?: string; tab?: string }>;
}) {
  const me = await requireStaff();
  const { day: rawDay, who: rawWho, tab } = await searchParams;
  const supabase = await createClient();

  const day = /^\d{4}-\d{2}-\d{2}$/.test(rawDay ?? "") ? rawDay! : today();
  const isAdmin = me.role === "Admin";
  const who = rawWho && /^[0-9a-f-]{36}$/.test(rawWho) ? rawWho : me.id;
  const mine = who === me.id;

  // ── Admin's list of everybody's days ──────────────────────
  if (tab === "everyone" && isAdmin) {
    const { data: days } = await supabase
      .from("staff_days")
      .select("id, staff_id, day, submitted_at")
      .gte("day", new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10))
      .order("day", { ascending: false })
      .limit(300);

    const { data: staff } = await supabase
      .from("staff")
      .select("id, name")
      .eq("is_system", false);
    const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));

    const rows: DataRow[] = (days ?? []).map((d) => ({
      key: d.id,
      text: `${staffName.get(d.staff_id) ?? ""} ${d.day}`,
      sort: { day: d.day, who: staffName.get(d.staff_id) ?? "" },
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
        <PageHead title="End of day" context="Every day submitted in the last month" />
        <nav className="segmented no-print" aria-label="Whose days">
          <Link href="/end-of-day">Mine</Link>
          <span aria-current="page">Everyone</span>
        </nav>
        <div className="card" style={{ padding: 0, marginTop: 10 }}>
          <DataTable
            label="days"
            columns={[
              { key: "day", label: "Day" },
              { key: "who", label: "Who" },
              { key: "state", label: "" },
            ]}
            rows={rows}
            pageSize={50}
            empty="No days have been submitted yet."
          />
        </div>
      </>
    );
  }

  // ── One person's day ──────────────────────────────────────
  const [{ data: person }, { data: existing }, { data: clients }] = await Promise.all([
    supabase.from("staff").select("id, name, role, manager_id").eq("id", who).maybeSingle(),
    supabase
      .from("staff_days")
      .select("id, bottlenecks, actions_taken, submitted_at, role_at_time, manager_id")
      .eq("staff_id", who)
      .eq("day", day)
      .maybeSingle(),
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
  ]);

  // A day nobody has opened yet exists only once somebody writes on it, so a
  // person looking at a colleague's blank day sees that it is blank rather
  // than one being created in their name.
  const dayId = existing?.id ?? null;

  const [{ data: lineRows }, { data: events }, { data: managerRow }] = await Promise.all([
    dayId
      ? supabase
          .from("staff_day_lines")
          .select("id, status, description, notes, client_id, carried_from, sort_order")
          .eq("day_id", dayId)
          .order("sort_order")
      : Promise.resolve({ data: [] as DayLine[] }),
    dayId
      ? supabase
          .from("staff_day_events")
          .select("action, reason, at")
          .eq("day_id", dayId)
          .order("at")
      : Promise.resolve({ data: [] as { action: string; reason: string; at: string }[] }),
    (existing?.manager_id ?? person?.manager_id)
      ? supabase
          .from("staff")
          .select("name")
          .eq("id", (existing?.manager_id ?? person?.manager_id)!)
          .maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const lines = (lineRows ?? []) as DayLine[];

  return (
    <>
      <PageHead
        title="End of day"
        context={
          mine
            ? "Your day, in the practice's own form"
            : `${person?.name ?? "Somebody"}'s day`
        }
      />

      {isAdmin && (
        <nav className="segmented no-print" aria-label="Whose days">
          <span aria-current={mine ? "page" : undefined}>{mine ? "Mine" : person?.name}</span>
          <Link href="/end-of-day?tab=everyone">Everyone</Link>
        </nav>
      )}

      <DayForm
        day={day}
        dayId={dayId}
        mine={mine}
        readOnly={!mine}
        submittedAt={existing?.submitted_at ?? null}
        header={{
          name: person?.name ?? "",
          role: existing?.role_at_time || (person?.role ?? ""),
          manager: managerRow?.name ?? "",
        }}
        lines={lines}
        bottlenecks={existing?.bottlenecks ?? ""}
        actionsTaken={existing?.actions_taken ?? ""}
        clients={clients ?? []}
        events={events ?? []}
      />
    </>
  );
}
