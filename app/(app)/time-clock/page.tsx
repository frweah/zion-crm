import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today , PRACTICE_TZ } from "@/lib/constants";
import { PageHead } from "../page-head";
import { WorkTimer } from "../hours/work-timer";
import { ConfirmClosed } from "./confirm-closed";
import { ClockTotalsTiles, CLOCK_TOTALS_COLUMNS } from "../clock-totals";

/**
 * The time clock (Design language, §3).
 *
 * The one thing most people do most often, on a screen of its own rather than
 * as a card half way down another: clock in, clock out, and the two figures
 * that answer "have I done enough today" and "what will this period pay" -
 * today's total and the period's.
 *
 * What is asked at clock-out is unchanged, because it was already right: the
 * hours from the clock, the category, and what the time was spent on. The
 * categories offered are the ones the person's role uses (0134).
 */
export default async function TimeClockPage() {
  const me = await requireStaff();
  const supabase = await createClient();
  const day = today();

  const [{ data: timer }, { data: summary }, { data: categories }, { data: clients }, { data: closed }, { data: segmentRows }] = await Promise.all([
    supabase
      .from("work_session_timers")
      .select("started_at, break_started_at, break_seconds")
      .maybeSingle(),
    supabase.from("my_hours_summary").select(CLOCK_TOTALS_COLUMNS).eq("staff_id", me.id).maybeSingle(),
    supabase.rpc("work_categories_for", { p_role: me.role }),
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
    // Sessions the fourteen-hour rule closed and nobody has looked at yet
    // (0293). The brief: the person must confirm or correct it next sign-in,
    // so it is at the top of this screen until they do.
    supabase
      .from("work_sessions")
      .select("id, worked_on, hours, started_at, ended_at")
      .eq("auto_closed", true)
      .is("confirmed_at", null)
      .order("worked_on", { ascending: false }),
    /*
     * Today's segments, in the order they were worked.
     *
     * A day is made of segments (owner, 14 Nov) and this is the screen where
     * somebody checks one against their own memory of the day. Voided rows
     * are left out: a segment somebody took back is not part of the day.
     */
    supabase
      .from("work_sessions")
      .select("id, hours, started_at, ended_at, break_seconds, description")
      .eq("worked_on", day)
      .eq("voided", false)
      .order("started_at", { ascending: true, nullsFirst: false }),
  ]);

  const segments = ((segmentRows ?? []) as {
    id: string;
    hours: number | string;
    started_at: string | null;
    ended_at: string | null;
    break_seconds: number | string;
    description: string;
  }[]).map((r) => ({
    id: r.id,
    hours: Number(r.hours),
    started_at: r.started_at,
    ended_at: r.ended_at,
    break_seconds: Number(r.break_seconds ?? 0),
    description: r.description ?? "",
  }));

  /** The time of day a segment started or finished, or a dash while it runs. */
  const clockTime = (at: string | null) =>
    at
      ? new Date(at).toLocaleTimeString("en-US", {
          timeZone: PRACTICE_TZ,
          hour: "numeric",
          minute: "2-digit",
        })
      : "—";

  return (
    <>
      <PageHead title="Time clock" context={me.name} />

      <ConfirmClosed sessions={(closed ?? []).map((c) => ({ ...c, hours: Number(c.hours) }))} />

      <p className="lock">
        {timer
          ? `${timer.break_started_at ? "On a break since" : "On the clock since"} ${new Date(
              timer.break_started_at ?? timer.started_at,
            ).toLocaleTimeString("en-US", { timeZone: PRACTICE_TZ, hour: "numeric", minute: "2-digit" })}`
          : "The clock is not running"}
      </p>

      <ClockTotalsTiles totals={summary ?? null} />

      {segments.length > 0 && (
        <table className="t" data-layout="the day's segments: when each one ran, and what it came to">
          <thead>
            <tr>
              <th>In</th>
              <th>Out</th>
              <th>Break</th>
              <th>Worked</th>
              <th>What it was</th>
            </tr>
          </thead>
          <tbody>
            {segments.map((seg) => (
              <tr key={seg.id}>
                <td>{clockTime(seg.started_at)}</td>
                <td>{clockTime(seg.ended_at)}</td>
                <td className="lock">{seg.break_seconds > 0 ? `${Math.round(seg.break_seconds / 60)} min` : "—"}</td>
                <td>{seg.hours.toFixed(2)}</td>
                <td>{seg.description || <span className="lock">Nothing said</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <WorkTimer
        running={timer ?? null}
        clients={clients ?? []}
        categories={((categories ?? []) as { key: string | null; label: string | null }[]).map((c) => ({
          key: c.key!,
          label: c.label!,
        }))}
        today={day}
      />

      <p className="lock">
        Everything you have logged is on <Link href="/hours">Time &amp; statements</Link>. A session logged by mistake is
        corrected there, with the reason kept beside it.
      </p>
    </>
  );
}
