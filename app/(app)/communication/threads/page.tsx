import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { NOTE_CATEGORIES } from "@/lib/report-shape";
import type { ThreadRow } from "@/lib/threads-board-shape";
import { PageHead } from "../../page-head";
import { ThreadsBoard } from "./threads-board";
import { ThreadPanel, type StreamItem } from "./thread-panel";
import { WebThread, type WebMessage } from "../../messages/texts/web-thread";

/**
 * Client threads (Communications brief, Part 2).
 *
 * One row per client, with every number and every channel folded into it, in
 * the groups a person works: who is waiting on an answer, what is waiting on
 * an approval, what did not go, who has gone quiet, who is not a client yet,
 * and everything else collapsed.
 *
 * It replaces three screens that each answered a narrower question and gave
 * three different numbers for "who is waiting on us" - 22, 8 and 4 on the day
 * it was measured (docs/timing/communications.md). The reading that survived
 * is the owner's: a reply is a reply on any channel, and the one place that
 * decides it is `client_threads_board`.
 *
 * Nothing is sent from a row. A row opens the thread beside it, and a text
 * goes from there, to a number that is named with its consent date - which is
 * the shape the Messaging brief gave the client record and the reason no
 * screen in this practice has ever sent a text somebody did not read first.
 */
export const dynamic = "force-dynamic";

export default async function ThreadsPage({
  searchParams,
}: {
  searchParams: Promise<{ c?: string; show?: string; chip?: string }>;
}) {
  const me = await requireStaff();
  const { c: open, show, chip } = await searchParams;

  const supabase = await createClient();
  const [{ data: rows, error }, { data: staff }] = await Promise.all([
    supabase.rpc("client_threads_board", {}),
    supabase.from("staff").select("id, name").eq("active", true).eq("is_system", false).order("name"),
  ]);

  /**
   * A read that failed is not an empty board.
   *
   * The lesson of 759ac17, on the screen next door: an error from the
   * database arrives as `data: null`, and a board that renders that as "ten
   * clients, nobody waiting" is a board that quietly says the opposite of the
   * truth. So the error surfaces, with its own sentence.
   */
  if (error) {
    return (
      <>
        <PageHead title="Client threads" context="Every client, every channel, and who is waiting" />
        <div className="card">
          <p style={{ margin: 0 }}>
            The board could not be read, so nothing below is known: {error.message}
          </p>
        </div>
      </>
    );
  }

  const all = ((rows ?? []) as unknown[]).map((r) => {
    const row = r as ThreadRow & { numbers: unknown };
    return {
      ...row,
      numbers: typeof row.numbers === "string" ? JSON.parse(row.numbers) : (row.numbers ?? []),
    } as ThreadRow;
  });

  // Which row is open. A client is opened by their id and a stranger by the
  // conversation's, because a stranger has no client to be opened by.
  const current = open
    ? (all.find((r) => r.kind === "client" && r.client_id === open) ??
      all.find((r) => r.conversation_id === open))
    : undefined;

  let stream: StreamItem[] = [];
  let web: WebMessage[] = [];
  if (current?.kind === "client" && current.client_id) {
    const { data } = await supabase.rpc("client_thread_stream", { p_client: current.client_id });
    stream = ((data ?? []) as unknown[]) as StreamItem[];
  } else if (current?.conversation_id) {
    const { data } = await supabase
      .from("messages")
      .select("id, seq, sender_kind, sender_label, body, created_at")
      .eq("conversation_id", current.conversation_id)
      .order("seq", { ascending: true })
      .limit(200);
    web = ((data ?? []) as unknown[]) as WebMessage[];
  }

  return (
    <>
      <PageHead
        title="Client threads"
        context="Every client, every channel, and who is waiting"
        actions={
          <Link className="btn ghost" href="/messages/texts" style={{ textDecoration: "none" }}>
            Spam and the portal
          </Link>
        }
      />

      <div className="board-pane">
        {current && (
          <div className="thread-side">
            {current.kind === "stranger" ? (
              <section className="card" aria-label={`Website chat with ${current.who}`}>
                <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
                  <h2 className="h2" style={{ margin: 0 }}>
                    {current.who} <span className="chip">{current.last_channel === "Website" ? "website" : "text"}</span>
                  </h2>
                  <Link
                    className="btn ghost"
                    href="/communication/threads"
                    style={{ textDecoration: "none", padding: "2px 10px" }}
                  >
                    Close
                  </Link>
                </div>
                {current.last_channel === "Website" ? (
                  <WebThread
                    conversationId={current.conversation_id!}
                    visitor={current.who}
                    messages={web}
                    canAnswer={["Admin", "Job Search", "Reports", "Job Coach", "Case Manager"].includes(me.role)}
                  />
                ) : (
                  <p className="lock" style={{ marginTop: 10 }}>
                    Nobody has said whose number this is, so there is nothing to answer on.{" "}
                    <Link href="/messages/texts?show=unmatched">Say whose it is</Link>, and the thread moves onto
                    their record.
                  </p>
                )}
              </section>
            ) : (
              <ThreadPanel
                row={current}
                items={stream}
                chip={chip ?? "all"}
                role={me.role}
                categories={[...NOTE_CATEGORIES]}
              />
            )}
          </div>
        )}

        <div>
          <ThreadsBoard
            rows={all}
            staff={staff ?? []}
            show={show ?? null}
            openKey={current?.row_key ?? null}
            role={me.role}
          />
        </div>
      </div>
    </>
  );
}
