import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";

/**
 * Is the documents agent running?
 *
 * An agent that quietly stopped three weeks ago looks exactly like a quiet
 * month, so this says when it was last heard from and what it found. It was the
 * top of the document inbox; it is part of the system, so it lives in
 * Admin → System.
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
  // It runs every fifteen minutes. Six hours of silence is a machine that is
  // off, which is normal overnight; a day is something to look at.
  const quiet = hoursSince !== null && hoursSince >= 24;

  return (
    <div className="card">
      {!last ? (
        <>
          <h3 style={{ marginTop: 0 }}>The agent has never been in touch</h3>
          <p className="sub" style={{ margin: 0 }}>
            Nothing has arrived yet. Run <code>install.cmd</code> from the agent folder on the machine
            that holds the client folders — it registers a task that runs every fifteen minutes and
            does one run straight away.
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
              It runs every fifteen minutes when the machine is on. A quiet night is normal; a quiet
              day is worth checking. On that machine: Task Scheduler, or{" "}
              <code>Get-ScheduledTaskInfo -TaskName &quot;Zion CRM document agent&quot;</code>.
            </p>
          )}

          <table className="t" style={{ marginTop: 10 }}>
            <tbody>
              {runs.slice(1).map((r) => (
                <tr key={r.ran_at}>
                  <td style={{ width: 190 }}>{fmtStamp(r.ran_at)}</td>
                  <td className="lock">
                    {r.files_seen} files, {r.files_new} new
                    {r.error && <span style={{ color: "var(--bad)" }}> · {r.error}</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  );
}
