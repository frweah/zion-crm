import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";

/**
 * The quarter-hourly pass, saying it ran (0383).
 *
 * The folder walk leaves a row in `inbox_runs`, so the agent card can say
 * when the folders were last read. The pass that reads phone photos sends no
 * manifest and leaves nothing, so the half of the agent that has to be quick
 * was the half nobody could see had stopped.
 *
 * One row, updated in place: ninety-six rows a day for the right to read the
 * newest one is a table something would have to trim, and the something
 * would be the next thing to stop quietly.
 *
 * Only the pass the quarter-hourly task runs calls this - the agent decides
 * that, because only the agent knows which task woke it - and it calls after
 * the photos are read, whether or not there were any. A pass that stamped
 * itself on the way in would report a run that then hung on Tesseract as a
 * healthy one.
 */
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  const secret = process.env.AGENT_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "AGENT_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("x-zion-agent") !== secret) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = (await request.json().catch(() => ({}))) as { photos?: unknown; machine?: unknown };
  const photos = Math.min(Math.max(Math.trunc(Number(body.photos) || 0), 0), 9999);
  const machine = typeof body.machine === "string" ? body.machine.slice(0, 60) : "";

  /**
   * What the card shows beside the time. The count is the useful half: a pass
   * that reads nothing for a week is a pass nobody is sending photos to, and
   * that is a different thing from a stopped task.
   */
  const detail = [`${photos} phone photo${photos === 1 ? "" : "s"} read`, machine && `from ${machine}`]
    .filter(Boolean)
    .join(" ");

  const supabase = createAdminClient();
  const { error } = await supabase
    .from("agent_heartbeat")
    .upsert({ kind: "light pass", at: new Date().toISOString(), detail }, { onConflict: "kind" });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ stamped: true });
}
