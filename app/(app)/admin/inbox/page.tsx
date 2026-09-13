import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today, fmtStamp, CAN_EDIT_BILLING } from "@/lib/constants";
import { InboxView, type PendingRow } from "./inbox-view";

/**
 * The document inbox.
 *
 * An agent on the owner's machine posts every PDF from the client folders.
 * Nothing it sends is filed on arrival — this is where a person looks at what
 * arrived and says what it is.
 *
 * The top of the screen answers "is it running?", because an agent that
 * quietly stopped three weeks ago looks exactly like a quiet month.
 */
const CAN_REVIEW = ["Admin", "Billing", "Job Search", "Reports"];

export default async function InboxPage() {
  const me = await requireStaff();
  if (!CAN_REVIEW.includes(me.role)) redirect("/dashboard");

  const supabase = await createClient();

  const [pendingResult, clientsResult, runsResult, doneResult] = await Promise.all([
    supabase.from("inbox_pending").select("*").order("first_seen", { ascending: false }),
    supabase.from("clients").select("id, name").order("name"),
    supabase
      .from("inbox_runs")
      .select("ran_at, machine, files_seen, files_new, folders_seen, error")
      .order("ran_at", { ascending: false })
      .limit(5),
    supabase
      .from("inbox_documents")
      .select("state")
      .neq("state", "Pending"),
  ]);

  const pending = (pendingResult.data ?? []) as unknown as PendingRow[];
  const runs = runsResult.data ?? [];
  const last = runs[0];
  const done = doneResult.data ?? [];

  const hoursSince = last
    ? Math.floor((Date.now() - new Date(last.ran_at).getTime()) / 3600000)
    : null;

  // It runs every fifteen minutes. Six hours of silence is a machine that is
  // off, which is normal overnight; a day is something to look at.
  const quiet = hoursSince !== null && hoursSince >= 24;

  return (
    <>
      <h1 className="h1">Document inbox</h1>
      <p className="sub">
        Everything the agent has found in the client folders, waiting for somebody to say what it
        is
      </p>

      <div className="card" style={{ margin: "14px 0" }}>
        {!last ? (
          <>
            <h3 style={{ marginTop: 0 }}>The agent has never been in touch</h3>
            <p className="sub" style={{ marginTop: 0 }}>
              Nothing has arrived yet. Run <code>install.cmd</code> from the agent folder on the
              machine that holds the client folders — it registers a task that runs every fifteen
              minutes and does one run straight away.
            </p>
          </>
        ) : (
          <>
            <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
              <div>
                <h3 style={{ margin: 0 }}>
                  {quiet ? (
                    <span style={{ color: "var(--bad)" }}>
                      Nothing heard for {hoursSince} hours
                    </span>
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
              <span className={"chip " + (quiet ? "bad" : "ok")}>
                {quiet ? "silent" : "heard from"}
              </span>
            </div>

            {last.error && <div className="alert bad" style={{ marginTop: 10 }}>{last.error}</div>}

            {quiet && (
              <p className="lock" style={{ margin: "10px 0 0" }}>
                It runs every fifteen minutes when the machine is on. A quiet night is normal; a
                quiet day is worth checking. On that machine: Task Scheduler, or{" "}
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

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", marginBottom: 18 }}
      >
        <div className="card">
          <div className="stat" style={pending.length > 0 ? { color: "var(--gold)" } : undefined}>
            {pending.length}
            <small>waiting for somebody</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {done.filter((d) => d.state === "Filed").length}
            <small>filed</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {done.filter((d) => d.state === "Ignored").length}
            <small>set aside</small>
          </div>
        </div>
      </div>

      <InboxView
        pending={pending}
        clients={clientsResult.data ?? []}
        today={today()}
        canBill={CAN_EDIT_BILLING.includes(me.role)}
      />

      <p className="lock" style={{ marginTop: 14 }}>
        The agent reads the folder and nothing else. It has never moved, renamed or deleted a file,
        and it cannot — what stops a document arriving twice is its content, not its name, so
        renaming or reorganising the folders on the machine is safe.
      </p>
    </>
  );
}
