import { createClient } from "@/lib/supabase/server";
import { DataTable } from "../../../data-table";
import { RecordingHours } from "./recording-hours";

/**
 * What the practice is paying to read (item F).
 *
 * The cost guard is twenty hours of recording a person a month, and this is
 * where it is read and where it is changed. On Money rather than on Settings
 * because it is a bill: Azure charges by the minute of audio, and the person
 * who decides whether to raise the limit is the person looking at what it
 * cost.
 *
 * Minutes already sent to Azure, not minutes recorded. A recording waiting in
 * the queue has cost nothing yet, and one that is held has cost nothing and
 * will not until somebody says so.
 */
export default async function RecordingsSection({ isAdmin }: { isAdmin: boolean }) {
  const supabase = await createClient();
  const [{ data: rows }, { data: settings }] = await Promise.all([
    supabase.rpc("recording_hours_by_person"),
    supabase.from("org_settings").select("recording_hours_per_person").maybeSingle(),
  ]);

  const people = (rows ?? []) as unknown as {
    staff_id: string;
    staff_name: string;
    minutes: number | null;
    hours: number | null;
    allowed_hours: number | null;
    recordings: number | null;
    held: number | null;
  }[];

  const allowed = Number(settings?.recording_hours_per_person ?? 20);
  const read = people.reduce((n, p) => n + Number(p.hours ?? 0), 0);
  const held = people.reduce((n, p) => n + Number(p.held ?? 0), 0);

  return (
    <>
      <h2 className="h2">Recordings read</h2>
      <p className="sub">
        This month, against {allowed} hours a person.</p>

      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))" }}>
        <div className="card">
          <div className="stat">
            {read.toFixed(1)}
            <small>hours read this month</small>
          </div>
        </div>
        <div className="card">
          <div className="stat" style={held > 0 ? { color: "var(--bad)" } : undefined}>
            {held}
            <small>held, over the month</small>
          </div>
        </div>
      </div>

      <div className="card" style={{ padding: 0, marginTop: 12 }}>
        <DataTable
          label="recording hours"
          sortBy
          columns={[
            { key: "person", label: "Person" },
            { key: "hours", label: "Hours read", align: "right" },
            { key: "left", label: "Left this month", align: "right" },
            { key: "count", label: "Recordings", align: "right" },
            { key: "held", label: "Held", align: "right" },
          ]}
          rows={people.map((p) => {
            const hours = Number(p.hours ?? 0);
            const left = Math.max(allowed - hours, 0);
            return {
              key: p.staff_id,
              text: p.staff_name,
              sort: { person: p.staff_name, hours, left, count: Number(p.recordings ?? 0), held: Number(p.held ?? 0) },
              cells: {
                person: p.staff_name,
                hours: hours.toFixed(1),
                left:
                  left === 0 ? (
                    <span className="chip bad">none</span>
                  ) : left <= 2 ? (
                    <span className="chip warn">{left.toFixed(1)}</span>
                  ) : (
                    left.toFixed(1)
                  ),
                count: Number(p.recordings ?? 0),
                held:
                  Number(p.held ?? 0) > 0 ? (
                    <span className="chip bad">{Number(p.held)}</span>
                  ) : (
                    <span className="lock">—</span>
                  ),
              },
            };
          })}
          empty="No recording has been read this month."
        />
      </div>

      {isAdmin && <RecordingHours allowed={allowed} />}
    </>
  );
}
