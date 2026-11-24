import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";
import { DataTable } from "../../data-table";

/**
 * Is the documents agent running?
 *
 * An agent that quietly stopped three weeks ago looks exactly like a quiet
 * month, so this says when it was last heard from and what it found. It was the
 * top of the document inbox, then in Admin → System; it is on Billing →
 * Documents now, under the inbox it feeds.
 */
export async function AgentStatus() {
  const supabase = await createClient();
  const { data } = await supabase
    .from("inbox_runs")
    .select("ran_at, machine, files_seen, files_new, folders_seen, error")
    .order("ran_at", { ascending: false })
    .limit(5);

  const runs = data ?? [];
  const last = runs[0];
  const hoursSince = last ? Math.floor((Date.now() - new Date(last.ran_at).getTime()) / 3600000) : null;
  /**
   * The folders are read at 10:00 and 19:00 (owner, 23 November 2026), so a
   * gap of a few hours is the ordinary state and a day is not.
   *
   * Only a full pass leaves a row here: the row is written by the manifest,
   * which is the folder walk asking what the CRM has not seen. The
   * quarter-hourly pass that reads phone photos sends no manifest and so
   * records nothing - this card says when the folders were last read, which
   * is what it is for, and not whether the photo task is alive.
   */
  const quiet = hoursSince !== null && hoursSince >= 24;

  return (
    <div className="card">
      {!last ? (
        <>
          <h3 style={{ marginTop: 0 }}>No contact yet</h3>
          <p className="sub" style={{ margin: 0 }}>
            Nothing has arrived yet. Run <code>install.cmd</code> from the agent folder on the machine
            that holds the client folders — it registers two tasks, one that reads the folders at
            10:00 and 19:00 and one that reads phone photos every fifteen minutes, and does one
            full run straight away.
          </p>
        </>
      ) : (
        <>
          <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
            <div>
              <h3 style={{ margin: 0 }}>
                {quiet ? (
                  <span style={{ color: "var(--bad)" }}>Nothing heard for {hoursSince} hours</span>
                ) : (
                  "The agent is running"
                )}
              </h3>
              <p className="sub" style={{ margin: "4px 0 0" }}>
                Last run {fmtStamp(last.ran_at)}
                {last.machine && ` from ${last.machine}`} — {last.files_seen} files across{" "}
                {last.folders_seen} folders, {last.files_new} new.
              </p>
            </div>
            <span className={"chip " + (quiet ? "bad" : "ok")}>{quiet ? "silent" : "heard from"}</span>
          </div>

          {last.error && (
            <div className="alert bad" style={{ marginTop: 10 }}>
              {last.error}
            </div>
          )}

          {quiet && (
            <p className="lock" style={{ margin: "10px 0 0" }}>
              The folders are read at 10:00 and 19:00 when the machine is on, so a few quiet hours
              are normal and a quiet day is worth checking. Run now above asks for an extra pass on
              the next wake. On that machine: Task Scheduler, or{" "}
              <code>Get-ScheduledTaskInfo -TaskName &quot;Zion CRM document agent&quot;</code>.
            </p>
          )}

          <h3 style={{ margin: "14px 0 6px", fontSize: "var(--text-base)", lineHeight: "22px" }}>The runs before</h3>
          <div style={{ border: "1px solid var(--line)", borderRadius: 6 }}>
            <DataTable
              label="agent runs"
              columns={[
                { key: "when", label: "When" },
                { key: "seen", label: "Files seen", align: "right" },
                { key: "new", label: "New", align: "right" },
                { key: "error", label: "Error" },
              ]}
              rows={runs.slice(1).map((r) => ({
                key: r.ran_at,
                sort: { when: r.ran_at, seen: Number(r.files_seen), new: Number(r.files_new), error: r.error },
                cells: {
                  when: fmtStamp(r.ran_at),
                  seen: Number(r.files_seen),
                  new: Number(r.files_new),
                  error: r.error ? (
                    <span style={{ color: "var(--bad)" }}>{r.error}</span>
                  ) : (
                    <span className="lock">—</span>
                  ),
                },
              }))}
              empty="There is no earlier run on record."
            />
          </div>
        </>
      )}
    </div>
  );
}
