import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";
import { PageHead } from "../page-head";
import { PresenceLabel } from "../live-messaging";
import { ThreadLive, Composer } from "./thread";
import { startDirect, setDigest } from "./actions";

/**
 * Messages (Messaging brief, the foundation).
 *
 * Staff conversations, live: the person's own list with what is unread, the
 * one open, and a way to message a colleague - with whether they are online,
 * away or offline, in words. Staff chat (B) builds on this screen - groups,
 * threads about a client, files, mentions - and texts (A) and the website
 * chat (C) join it. What anybody can read is the database's rule (0104).
 */
type Conv = {
  id: string;
  kind: string;
  title: string;
  client_id: string | null;
  last_message_at: string | null;
  last_seq: number;
};

export default async function MessagesPage({ searchParams }: { searchParams: Promise<{ c?: string; error?: string }> }) {
  const me = await requireStaff();
  const { c: openId, error } = await searchParams;
  const supabase = await createClient();

  const [{ data: mine }, { data: unreadRows }, { data: presence }, { data: staff }, { data: digest }] = await Promise.all([
    supabase
      .from("conversation_participants")
      .select("conversation_id, conversation:conversations(id, kind, title, client_id, last_message_at, last_seq)")
      .eq("staff_id", me.id)
      .is("left_at", null),
    supabase.rpc("my_unread"),
    supabase.rpc("staff_presence_status"),
    supabase.from("staff").select("id, name").eq("active", true).order("name"),
    supabase.from("staff_prefs").select("key").eq("key", "messages:email_digest").maybeSingle(),
  ]);

  const convs = ((mine ?? []) as unknown as { conversation: Conv | Conv[] | null }[])
    .map((r) => (Array.isArray(r.conversation) ? r.conversation[0] : r.conversation))
    .filter((c): c is Conv => Boolean(c))
    .sort((a, b) => (b.last_message_at ?? "").localeCompare(a.last_message_at ?? ""));
  const ids = convs.map((c) => c.id);
  const none = ["00000000-0000-0000-0000-000000000000"];

  const [{ data: members }, { data: clients }, openResult] = await Promise.all([
    supabase
      .from("conversation_participants")
      .select("conversation_id, staff_id")
      .in("conversation_id", ids.length ? ids : none)
      .is("left_at", null),
    supabase.from("clients").select("id, name").in("id", convs.map((c) => c.client_id).filter(Boolean) as string[]),
    openId
      ? supabase
          .from("messages")
          .select("id, seq, sender_kind, sender_staff_id, sender_label, body, created_at, removed_at")
          .eq("conversation_id", openId)
          .order("seq", { ascending: false })
          .limit(200)
      : Promise.resolve({ data: null }),
  ]);

  const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));
  const status = new Map((presence ?? []).map((p) => [p.staff_id, p.status]));
  const unread = new Map((unreadRows ?? []).map((u) => [u.conversation_id, u.unread ?? 0]));
  const clientName = new Map((clients ?? []).map((c) => [c.id, c.name]));
  const others = (conv: string) =>
    (members ?? []).filter((m) => m.conversation_id === conv && m.staff_id !== me.id).map((m) => m.staff_id);
  const labelOf = (c: Conv) =>
    c.title ||
    (c.client_id ? `About ${clientName.get(c.client_id) ?? "a client"}` : others(c.id).map((id) => staffName.get(id) ?? "—").join(", ")) ||
    "Just you";

  const open = convs.find((c) => c.id === openId) ?? null;
  const thread = open ? [...(openResult.data ?? [])].reverse() : [];
  const colleagues = (staff ?? []).filter((s) => s.id !== me.id);

  return (
    <>
      <PageHead title="Messages" context="Conversations with colleagues, as they happen" />
      {error && <div className="alert bad">{error}</div>}

      <div className="mail-layout">
        <div>
          <form action={startDirect} className="card" style={{ marginBottom: 12 }}>
            <label className="field" style={{ margin: 0 }}>
              Message a colleague
              <select id="chat-new" name="staff_id" required defaultValue="">
                <option value="" disabled>
                  Choose…
                </option>
                {colleagues.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name} ({status.get(s.id) ?? "offline"})
                  </option>
                ))}
              </select>
            </label>
            <button className="btn gold" type="submit" style={{ marginTop: 8 }}>
              Open conversation
            </button>
          </form>

          <div className="card" style={{ padding: 0 }}>
            {convs.length === 0 ? (
              <p className="empty" style={{ padding: 16, margin: 0 }}>
                No conversations yet.
              </p>
            ) : (
              <ul className="mail-list">
                {convs.map((c) => {
                  const n = unread.get(c.id) ?? 0;
                  const firstOther = others(c.id)[0];
                  return (
                    <li key={c.id}>
                      <Link
                        href={`/messages?c=${c.id}`}
                        className={"mail-row" + (c.id === openId ? " on" : "") + (n > 0 ? " unread" : "")}
                        aria-current={c.id === openId ? "true" : undefined}
                      >
                        <span className="mail-who">
                          {n > 0 && <span className="chip gold">{n} new</span>} {labelOf(c)}
                        </span>
                        <span className="mail-when">{c.last_message_at ? fmtStamp(c.last_message_at) : ""}</span>
                        {!c.title && !c.client_id && firstOther && (
                          <span className="mail-tags">
                            <PresenceLabel status={status.get(firstOther) ?? "offline"} />
                          </span>
                        )}
                      </Link>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>

          <form action={setDigest} className="lock" style={{ marginTop: 10 }}>
            <input type="hidden" name="on" value={digest ? "no" : "yes"} />
            {digest
              ? "You are emailed about unread messages after thirty minutes away - how many and from whom, never the text. "
              : "You are not emailed about unread messages. "}
            <button type="submit" className="btn ghost" style={{ padding: "2px 10px" }}>
              {digest ? "Stop the email" : "Email me after 30 minutes away"}
            </button>
          </form>
        </div>

        <div>
          {!open ? (
            <div className="card">
              <p className="empty" style={{ margin: 0 }}>
                {openId ? "That conversation is not one of yours." : "Choose a conversation, or message a colleague."}
              </p>
            </div>
          ) : (
            <section className="card thread" aria-label={labelOf(open)}>
              <header className="thread-head">
                <h2 className="h2" style={{ margin: 0 }}>
                  {labelOf(open)}
                </h2>
                <div className="row2" style={{ gap: 10 }}>
                  {others(open.id).map((id) => (
                    <span key={id} className="lock">
                      {staffName.get(id) ?? "—"} · <PresenceLabel status={status.get(id) ?? "offline"} />
                    </span>
                  ))}
                </div>
              </header>
              <ol className="thread-list">
                {thread.length === 0 && <li className="empty">Nothing said yet.</li>}
                {thread.map((m) => {
                  const mineMsg = m.sender_staff_id === me.id;
                  return (
                    <li key={m.id} className={"bubble" + (mineMsg ? " mine" : "")}>
                      <div className="lock">
                        {mineMsg ? "You" : m.sender_label || m.sender_kind} · {fmtStamp(m.created_at)}
                      </div>
                      <div className="bubble-text">{m.removed_at ? <i>Message removed</i> : m.body}</div>
                    </li>
                  );
                })}
              </ol>
              <ThreadLive conversationId={open.id} lastSeq={thread.length ? Number(thread[thread.length - 1].seq) : 0} />
              {open.kind === "internal" && <Composer conversationId={open.id} />}
            </section>
          )}
        </div>
      </div>
    </>
  );
}
