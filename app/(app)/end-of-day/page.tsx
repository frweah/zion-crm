import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { PageHead } from "../page-head";
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
  searchParams: Promise<{ day?: string; who?: string }>;
}) {
  const me = await requireStaff();
  const { day: rawDay, who: rawWho } = await searchParams;
  const supabase = await createClient();

  const day = /^\d{4}-\d{2}-\d{2}$/.test(rawDay ?? "") ? rawDay! : today();
  const who = rawWho && /^[0-9a-f-]{36}$/.test(rawWho) ? rawWho : me.id;
  const mine = who === me.id;

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

  const [{ data: lineRows }, { data: events }, { data: managerRow }, { data: clocked }] = await Promise.all([
    dayId
      ? supabase
          .from("staff_day_lines")
          .select(
            "id, status, description, notes, client_id, carried_from, sort_order, from_clock_out, staff_file_id, attachment_id",
          )
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
    /*
     * What the clock says about **this** day, so somebody writing it up is
     * not asked to remember it (0293, item 7). Shown rather than filled into
     * a field: End of day records what was done, not how long it took.
     *
     * Read from `work_days` for the day on the screen rather than from the
     * summary view, which only ever answered for today - so a person opening
     * yesterday from the flag on My day was shown today's hours beside
     * yesterday's work.
     */
    supabase
      .from("work_days")
      .select("worked_hours, break_seconds, segments")
      .eq("staff_id", who)
      .eq("day", day)
      .maybeSingle(),
  ]);

  /*
   * The names of the files attached at clock out.
   *
   * Looked up here rather than joined, because the two files live in two
   * tables with two different access rules and a join would have to pick
   * one. Read as the person asking: a name that does not come back is a file
   * they may not open, and the line simply does not offer it.
   */
  const rawLines = (lineRows ?? []) as DayLine[];
  const staffFileIds = rawLines.map((l) => l.staff_file_id).filter((id): id is string => Boolean(id));
  const attachmentIds = rawLines.map((l) => l.attachment_id).filter((id): id is string => Boolean(id));
  const [{ data: staffFileRows }, { data: attachmentRows }] = await Promise.all([
    staffFileIds.length
      ? supabase.from("staff_files").select("id, filename").in("id", staffFileIds)
      : Promise.resolve({ data: [] as { id: string; filename: string }[] }),
    attachmentIds.length
      ? supabase.from("client_documents").select("id, filename").in("id", attachmentIds)
      : Promise.resolve({ data: [] as { id: string; filename: string | null }[] }),
  ]);
  const fileNames = new Map<string, string>();
  for (const f of staffFileRows ?? []) fileNames.set(f.id, f.filename);
  for (const f of attachmentRows ?? []) if (f.id && f.filename) fileNames.set(f.id, f.filename);

  const lines: DayLine[] = rawLines.map((l) => ({
    ...l,
    file_name: fileNames.get(l.staff_file_id ?? l.attachment_id ?? "") ?? null,
  }));
  const clockedHours = Number(clocked?.worked_hours ?? 0);
  const clockedBreak = Number(clocked?.break_seconds ?? 0);
  const clockedSegments = Number(clocked?.segments ?? 0);

  return (
    <>
      {clockedHours > 0 && (
        <p className="lock" style={{ marginBottom: 10 }}>
          The clock has {clockedHours.toFixed(2)} hours {mine ? "for you" : `for ${person?.name ?? "them"}`} on this
          day
          {clockedSegments > 1 ? `, across ${clockedSegments} segments` : ""}
          {clockedBreak > 0 ? `, and ${Math.round(clockedBreak / 60)} minutes of break` : ""}.
        </p>
      )}

      <PageHead
        title="My end of day"
        context={
          mine
            ? "Your day, in the practice's own form"
            : `${person?.name ?? "Somebody"}'s day`
        }
        actions={
          /*
           * Somebody who manages somebody gets here from their own day as
           * well as from HR (owner, 23 Oct 2026). The team view has always
           * been in the navigation for a manager, but a manager filling in
           * their own day is exactly when they think of reading their
           * people's, and the way there was a different group.
           */
          me.manages ? (
            <Link className="btn ghost" href="/end-of-day/team" style={{ textDecoration: "none" }}>
              The team&apos;s days
            </Link>
          ) : undefined
        }
      />

      {!mine && (
        <nav className="segmented no-print" aria-label="Whose day">
          <Link href="/end-of-day">Mine</Link>
          <span aria-current="page">{person?.name}</span>
          <Link href="/end-of-day/team">The team</Link>
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
