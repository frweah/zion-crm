import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";
import { teamsChatHref } from "@/lib/teams";
import { PageHead } from "../page-head";
import { PresenceLabel } from "../live-messaging";
import {
  ThreadLive,
  Composer,
  MessageText,
  MessageActions,
  AttachmentButton,
  AddPerson,
  type Attachable,
} from "./thread";
import { startDirect, startGroup, setDigest, leaveConversation, archiveConversation, type ChatAttachment } from "./actions";

/**
 * Messages (Messaging brief, the foundation and B).
 *
 * Staff conversations, live: the person's own list with what is unread, the
 * one open, and a way to message a colleague or start a group - with whether
 * each person is online, away or offline, in words.
 *
 * Staff chat (B) added to this screen: named groups anybody can start, threads
 * about a client that show on that client's Activity, documents attached by
 * reference from a client's record, mentions, five minutes to correct a
 * message, removing your own, and search across the conversations you are in.
 * What anybody can read is the database's rule (0104, 0106), not this screen's.
 *
 * Teams is alongside, not replaced: every conversation here offers the same
 * people in Teams, for everything that does not belong on a client's record.
 */
type Conv = {
  id: string;
  kind: string;
  title: string;
  client_id: string | null;
  created_by: string | null;
  last_message_at: string | null;
  last_seq: number;
  archived_at: string | null;
};

export default async function MessagesPage({
  searchParams,
}: {
  searchParams: Promise<{ c?: string; error?: string; q?: string; archived?: string }>;
}) {
  const me = await requireStaff();
  const { c: openId, error, q, archived: showArchived } = await searchParams;
  const search = (q ?? "").trim();
  const supabase = await createClient();

  const [{ data: mine }, { data: unreadRows }, { data: presence }, { data: staff }, { data: digest }, { data: found }] =
    await Promise.all([
      supabase
        .from("conversation_participants")
        .select(
          "conversation_id, conversation:conversations(id, kind, title, client_id, created_by, last_message_at, last_seq, archived_at)",
        )
        .eq("staff_id", me.id)
        .is("left_at", null),
      supabase.rpc("my_unread"),
      supabase.rpc("staff_presence_status"),
      supabase.from("staff").select("id, name, email").eq("active", true).order("name"),
      supabase.from("staff_prefs").select("key").eq("key", "messages:email_digest").maybeSingle(),
      search ? supabase.rpc("search_messages", { p_query: search }) : Promise.resolve({ data: null }),
    ]);

  const all = ((mine ?? []) as unknown as { conversation: Conv | Conv[] | null }[])
    .map((r) => (Array.isArray(r.conversation) ? r.conversation[0] : r.conversation))
    .filter((c): c is Conv => Boolean(c))
    .sort((a, b) => (b.last_message_at ?? "").localeCompare(a.last_message_at ?? ""));
  const archivedCount = all.filter((c) => c.archived_at).length;
  const convs = showArchived ? all : all.filter((c) => !c.archived_at);
  const ids = all.map((c) => c.id);
  const none = ["00000000-0000-0000-0000-000000000000"];

  const [{ data: members }, { data: clients }, openResult] = await Promise.all([
    supabase
      .from("conversation_participants")
      .select("conversation_id, staff_id")
      .in("conversation_id", ids.length ? ids : none)
      .is("left_at", null),
    supabase.from("clients").select("id, name").in("id", all.map((c) => c.client_id).filter(Boolean) as string[]),
    openId
      ? supabase
          .from("messages")
          .select("id, seq, sender_kind, sender_staff_id, sender_label, body, attachments, mentions, created_at, edited_at, removed_at")
          .eq("conversation_id", openId)
          .order("seq", { ascending: false })
          .limit(200)
      : Promise.resolve({ data: null }),
  ]);

  const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));
  const staffEmail = new Map((staff ?? []).map((s) => [s.id, s.email]));
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
  const isDirect = Boolean(open && !open.title && !open.client_id);

  // A thread about a client offers that client's documents, by reference. The
  // restricted ones this person may not see are not in the list at all - the
  // documents rule (0009) decided that before this screen was drawn.
  let documents: Attachable[] = [];
  let canSeeRestricted = false;
  if (open?.client_id) {
    const [{ data: files }, { data: forms }, { data: mayRestrict }] = await Promise.all([
      supabase.from("attachments").select("id, filename, restricted").eq("client_id", open.client_id).order("created_at", { ascending: false }).limit(50),
      supabase.from("forms").select("id, sensitive, template:form_templates(name)").eq("client_id", open.client_id).order("created_at", { ascending: false }).limit(25),
      supabase.rpc("can_see_restricted", { p_client_id: open.client_id }),
    ]);
    canSeeRestricted = Boolean(mayRestrict);
    documents = [
      ...(files ?? []).map((f) => ({ kind: "client_file" as const, id: f.id, name: f.filename, restricted: f.restricted })),
      ...((forms ?? []) as unknown as { id: string; sensitive: boolean; template: { name: string } | { name: string }[] | null }[]).map((f) => ({
        kind: "form" as const,
        id: f.id,
        name: (Array.isArray(f.template) ? f.template[0]?.name : f.template?.name) ?? "Form",
        restricted: f.sensitive,
      })),
    ];
  }

  const participants = open ? others(open.id).map((id) => ({ id, name: staffName.get(id) ?? "—" })) : [];
  const teamsHref = open ? teamsChatHref(others(open.id).map((id) => staffEmail.get(id))) : null;
  const canArchive = Boolean(open && !isDirect && (me.role === "Admin" || open.created_by === me.id));

  return (
    <>
      <PageHead title="Messages" context="Conversations with colleagues, as they happen" />
      {error && <div className="alert bad">{error}</div>}

      <div className="mail-layout">
        <div>
          <form className="card" style={{ marginBottom: 12 }}>
            <label className="field" style={{ margin: 0 }}>
              Search what has been said
              <input id="chat-search" name="q" type="search" defaultValue={search} placeholder="A word, a name, a number" />
            </label>
            <button className="btn" type="submit" style={{ marginTop: 8 }}>
              Search
            </button>
            {search && (
              <>
                {" "}
                <Link className="btn ghost" href="/messages">
                  Clear
                </Link>
              </>
            )}
          </form>

          <details className="card" style={{ marginBottom: 12 }}>
            <summary>Start a conversation</summary>
            <form action={startDirect} style={{ marginTop: 10 }}>
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

            <form action={startGroup} style={{ marginTop: 14, borderTop: "1px solid var(--line)", paddingTop: 12 }}>
              <label className="field" style={{ margin: 0 }}>
                Or start a group
                <input id="group-title" name="title" required maxLength={80} placeholder="What it is for — e.g. Monday intake" />
              </label>
              <label className="field" style={{ marginTop: 8 }}>
                Who is in it
                <select id="group-staff" name="staff_id" multiple size={Math.min(6, Math.max(3, colleagues.length))}>
                  {colleagues.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
              </label>
              <button className="btn gold" type="submit" style={{ marginTop: 8 }}>
                Start the group
              </button>
              <p className="lock" style={{ margin: "8px 0 0" }}>
                A conversation about a client is started from that client&apos;s record instead, so it lands on their
                Activity.
              </p>
            </form>
          </details>

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
                        href={`/messages?c=${c.id}${showArchived ? "&archived=1" : ""}`}
                        className={"mail-row" + (c.id === openId ? " on" : "") + (n > 0 ? " unread" : "")}
                        aria-current={c.id === openId ? "true" : undefined}
                      >
                        <span className="mail-who">
                          {n > 0 && <span className="chip gold">{n} new</span>} {labelOf(c)}
                          {c.archived_at && <span className="chip"> archived</span>}
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

          {archivedCount > 0 && (
            <p className="lock" style={{ marginTop: 10 }}>
              <Link href={showArchived ? "/messages" : "/messages?archived=1"}>
                {showArchived ? "Hide archived conversations" : `Show ${archivedCount} archived`}
              </Link>
            </p>
          )}

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
          {search ? (
            <section className="card" aria-label={`What was said about ${search}`}>
              <h2 className="h2" style={{ marginTop: 0 }}>
                “{search}” in your conversations
              </h2>
              {(found ?? []).length === 0 ? (
                <p className="empty" style={{ margin: 0 }}>
                  Nothing said that you can read. Search reaches the conversations you are in, and no further.
                </p>
              ) : (
                <ul className="mail-list">
                  {(found ?? []).map((r) => (
                    <li key={r.message_id}>
                      <Link href={`/messages?c=${r.conversation_id}`} className="mail-row">
                        <span className="mail-who">{r.conversation_label}</span>
                        <span className="mail-when">{fmtStamp(r.created_at)}</span>
                        <span className="mail-tags">
                          {r.sender_label}: {(r.body ?? "").length > 160 ? (r.body ?? "").slice(0, 160) + "…" : r.body}
                        </span>
                      </Link>
                    </li>
                  ))}
                </ul>
              )}
            </section>
          ) : !open ? (
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
                  {open.archived_at && <span className="chip"> archived</span>}
                </h2>
                {open.client_id && (
                  <p className="lock" style={{ margin: 0 }}>
                    About <Link href={`/clients/${open.client_id}`}>{clientName.get(open.client_id) ?? "a client"}</Link> —
                    this thread is on their Activity, and goes into their file if their record is ever produced.
                  </p>
                )}
                <div className="row2" style={{ gap: 10, flexWrap: "wrap" }}>
                  {participants.map((p) => (
                    <span key={p.id} className="lock">
                      {p.name} · <PresenceLabel status={status.get(p.id) ?? "offline"} />
                    </span>
                  ))}
                </div>
                <div className="row2" style={{ gap: 10, flexWrap: "wrap", alignItems: "center" }}>
                  {teamsHref && (
                    <a className="btn ghost" href={teamsHref} target="_blank" rel="noopener noreferrer" style={{ padding: "2px 10px" }}>
                      Message on Teams
                    </a>
                  )}
                  {!isDirect && !open.archived_at && <AddPerson conversationId={open.id} candidates={colleagues.filter((s) => !participants.some((p) => p.id === s.id))} />}
                  {!isDirect && (
                    <form action={leaveConversation} style={{ display: "inline" }}>
                      <input type="hidden" name="conversation_id" value={open.id} />
                      <button type="submit" className="linkish">
                        Leave
                      </button>
                    </form>
                  )}
                  {canArchive && (
                    <form action={archiveConversation} style={{ display: "inline" }}>
                      <input type="hidden" name="conversation_id" value={open.id} />
                      <input type="hidden" name="archived" value={open.archived_at ? "no" : "yes"} />
                      <button type="submit" className="linkish">
                        {open.archived_at ? "Bring it back" : "Archive"}
                      </button>
                    </form>
                  )}
                </div>
              </header>

              <ol className="thread-list">
                {thread.length === 0 && <li className="empty">Nothing said yet.</li>}
                {thread.map((m) => {
                  const mineMsg = m.sender_staff_id === me.id;
                  const mentionsMe = ((m.mentions ?? []) as string[]).includes(me.id);
                  const files = (m.attachments ?? []) as unknown as ChatAttachment[];
                  return (
                    <li key={m.id} className={"bubble" + (mineMsg ? " mine" : "") + (mentionsMe ? " mentions-me" : "")}>
                      <div className="lock">
                        {mineMsg ? "You" : m.sender_label || m.sender_kind} · {fmtStamp(m.created_at)}
                        {m.edited_at && !m.removed_at && " · corrected"}
                        {mentionsMe && <span className="chip gold"> mentions you</span>}
                      </div>
                      <div className="bubble-text">
                        {m.removed_at ? (
                          <i>Message removed</i>
                        ) : (
                          <MessageText body={m.body} names={[...participants.map((p) => p.name), me.name]} />
                        )}
                      </div>
                      {files.length > 0 && !m.removed_at && (
                        <ul className="attach-row" aria-label="Attached">
                          {files.map((f) => (
                            <li key={f.id}>
                              <AttachmentButton attachment={f} />
                            </li>
                          ))}
                        </ul>
                      )}
                      {mineMsg && !m.removed_at && (
                        <MessageActions messageId={m.id} body={m.body} createdAt={m.created_at} />
                      )}
                    </li>
                  );
                })}
              </ol>

              <ThreadLive conversationId={open.id} lastSeq={thread.length ? Number(thread[thread.length - 1].seq) : 0} />

              {open.archived_at ? (
                <p className="lock" style={{ marginTop: 10 }}>
                  This conversation is archived. What was said is kept; nothing more can be added.
                </p>
              ) : (
                open.kind === "internal" && (
                  <Composer
                    conversationId={open.id}
                    clientId={open.client_id}
                    clientName={open.client_id ? (clientName.get(open.client_id) ?? "the client") : ""}
                    participants={participants}
                    documents={documents}
                    canSeeRestricted={canSeeRestricted}
                  />
                )
              )}
            </section>
          )}
        </div>
      </div>
    </>
  );
}
