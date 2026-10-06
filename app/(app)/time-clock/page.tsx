import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { PageHead } from "../page-head";
import { WorkTimer } from "../hours/work-timer";

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

  const [{ data: timer }, { data: summary }, { data: categories }, { data: clients }] = await Promise.all([
    supabase.from("work_session_timers").select("started_at").maybeSingle(),
    supabase.from("my_hours_summary").select("today_hours, period_hours, period_start, period_end").maybeSingle(),
    supabase.rpc("work_categories_for", { p_role: me.role }),
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
  ]);

  const todayHours = Number(summary?.today_hours ?? 0);
  const periodHours = Number(summary?.period_hours ?? 0);

  return (
    <>
      <PageHead title="Time clock" context={me.name} />

      <div className="tiles">
        <div className="tile tile-lead">
          <span className="tile-label">{timer ? "Clocked in" : "Not clocked in"}</span>
          <span className="tile-value">
            {timer ? new Date(timer.started_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : "—"}
          </span>
          <span className="tile-note">{timer ? "since" : "the clock is not running"}</span>
        </div>
        <div className="tile">
          <span className="tile-label">Today</span>
          <span className="tile-value">{todayHours.toFixed(2)}</span>
          <span className="tile-note">hours logged</span>
        </div>
        <div className="tile">
          <span className="tile-label">This period</span>
          <span className="tile-value">{periodHours.toFixed(2)}</span>
          <span className="tile-note">
            {summary?.period_start ? `${summary.period_start} to ${summary.period_end}` : "hours logged"}
          </span>
        </div>
      </div>

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
        Everything you have logged, and your statements, are on <Link href="/hours">Hours</Link>. A session logged by
        mistake is corrected there, with the reason kept beside it.
      </p>
    </>
  );
}
