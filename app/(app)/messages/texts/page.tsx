import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp, CAN_EDIT_CLIENTS } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";
import { AssignForm, UnmatchedActions, NotSpam } from "./inbox-forms";
import { WebThread, type WebMessage } from "./web-thread";

/**
 * The inbox (Messaging brief, A and C).
 *
 * Every conversation the practice has with somebody outside it: texts both
 * ways, and chats started on the website. Who it is with, what was last said,
 * who is looking after it, and how much of it you have not read.
 *
 * A message from somebody nobody knows - a number or a name off the website -
 * sits at the top until somebody says whose it is, starts a referral, or
 * marks it spam. None of them is ever dropped.
 *
 * A text is answered on the client's record, where consent and the sending
 * hours are checked. A website chat is answered here, because the person on
 * the other end may not be anybody the practice knows yet.
 */
const VIEWS = [
  { key: "open", label: "All open" },
  { key: "mine", label: "Mine" },
  { key: "web", label: "Website" },
  { key: "texts", label: "Texts" },
  { key: "unmatched", label: "Unmatched" },
  { key: "spam", label: "Spam" },
] as const;

export default async function InboxPage({ searchParams }: { searchParams: Promise<{ show?: string; c?: string; tab?: string }> }) {
  const me = await requireStaff();
  const { show: rawShow, c: openId, tab } = await searchParams;
  // Inbox → Texts and Inbox → Website chat are this screen, shown two ways
  // (21 Sept 2026). The finer views below still narrow either.
  const asked = rawShow ?? (tab === "web" ? "web" : tab === "texts" ? "texts" : undefined);
  const show = VIEWS.some((v) => v.key === asked) ? asked! : "open";
  const canWork = CAN_EDIT_CLIENTS.includes(me.role);

  const supabase = await createClient();
  const [{ data: rows }, { data: staff }, { data: clients }] = await Promise.all([
    supabase.rpc("message_inbox", { p_show: show }),
    supabase.from("staff").select("id, name").eq("active", true).order("name"),
    supabase.from("clients").select("id, name").neq("status", "Closed").order("name"),
  ]);

  const inbox = rows ?? [];
  const unmatched = inbox.filter((r) => r.unmatched).length;
  const staffList = staff ?? [];
  const clientList = clients ?? [];

  // The one open website chat, if a row was clicked into.
  const open = openId ? inbox.find((r) => r.conversation_id === openId && r.kind === "web") : undefined;
  const [{ data: thread }, { data: visitorRow }] = open
    ? await Promise.all([
        supabase
          .from("messages")
          .select("id, seq, sender_kind, sender_label, body, created_at")
          .eq("conversation_id", openId!)
          .order("seq", { ascending: true })
          .limit(200),
        supabase.from("web_chats").select("visitor_name, contact, consent_text, consent_at").eq("conversation_id", openId!).maybeSingle(),
      ])
    : [{ data: null }, { data: null }];

  return (
    <>
      <PageHead
        title="Texts &amp; web"
        context="Every conversation with somebody outside the practice, and what has not been answered"
        actions={
          <Link className="btn ghost" href="/messages" style={{ textDecoration: "none" }}>
            Staff messages
          </Link>
        }
      />

      <div className="row2 no-print" style={{ justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
        <div className="segmented" role="group" aria-label="Which conversations">
          {VIEWS.map((v) => (
            <Link key={v.key} href={`/messages/texts?show=${v.key}`} className={v.key === show ? "on" : undefined}>
              {v.label}
              {v.key === "unmatched" && unmatched > 0 && show !== "unmatched" ? ` (${unmatched})` : ""}
            </Link>
          ))}
        </div>
      </div>

      {open && (
        <section className="card" style={{ marginBottom: 14 }} aria-label={`Website chat with ${visitorRow?.visitor_name ?? "a visitor"}`}>
          <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
            <div>
              <h2 className="h2" style={{ margin: 0 }}>
                {visitorRow?.visitor_name ?? "A visitor"} <span className="chip">website</span>
              </h2>
              <p className="lock" style={{ margin: "2px 0 0" }}>
                {visitorRow?.contact}
                {open.client_id && (
                  <>
                    {" · "}
                    <Link href={`/clients/${open.client_id}`}>{open.client_name}</Link>
                  </>
                )}
              </p>
            </div>
            <Link className="btn ghost" href={`/messages/texts?show=${show}`} style={{ textDecoration: "none", padding: "2px 10px" }}>
              Close
            </Link>
          </div>

          <WebThread
            conversationId={openId!}
            visitor={visitorRow?.visitor_name ?? "The visitor"}
            messages={(thread ?? []) as WebMessage[]}
            canAnswer={canWork}
          />

          <p className="lock" style={{ marginTop: 10, marginBottom: 0 }}>
            {visitorRow?.consent_at
              ? `They agreed on ${fmtStamp(visitorRow.consent_at)}: “${visitorRow.consent_text}”`
              : "No consent recorded with this conversation."}{" "}
            Agreeing to be contacted here is not agreeing to be texted - that is still recorded on their record.
          </p>
        </section>
      )}

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="conversations"
          sortBy
          pageSize={50}
          columns={[
            { key: "who", label: "Who" },
            { key: "last", label: "Last message" },
            { key: "when", label: "When" },
            { key: "assigned", label: "Assigned", sortable: false },
            { key: "do", label: "", sortable: false },
          ]}
          rows={inbox.map((r) => ({
            key: r.conversation_id!,
            cells: {
              who: (
                <>
                  {r.client_id ? (
                    <Link href={`/clients/${r.client_id}?tab=messages`} style={{ color: "var(--teal)" }}>
                      <b>{r.client_name}</b>
                    </Link>
                  ) : (
                    <b>{r.who || "(no contact)"}</b>
                  )}
                  <div className="lock">
                    <span className="chip">{r.kind === "web" ? "Website" : "Text"}</span>{" "}
                    {r.client_id ? r.who : "Not matched to anybody"}
                    {(r.unread ?? 0) > 0 && (
                      <>
                        {" "}
                        <span className="chip gold">{r.unread} unread</span>
                      </>
                    )}
                    {r.kind === "sms" && r.client_id && !r.can_text && (
                      <>
                        {" "}
                        <span className="chip bad">Cannot text</span>
                      </>
                    )}
                    {r.spam && (
                      <>
                        {" "}
                        <span className="chip">Spam</span>
                      </>
                    )}
                  </div>
                </>
              ),
              last: <span className="lock">{(r.last_body ?? "").slice(0, 120)}</span>,
              when: <span style={{ whiteSpace: "nowrap" }}>{r.last_message_at ? fmtStamp(r.last_message_at) : ""}</span>,
              assigned: canWork ? (
                <AssignForm conversationId={r.conversation_id!} assignedTo={r.assigned_staff_id} staff={staffList} />
              ) : (
                (r.assigned_name ?? "—")
              ),
              do: (
                <div className="row2" style={{ gap: 6, flexWrap: "wrap" }}>
                  {r.kind === "web" && (
                    <Link
                      className="btn ghost"
                      href={`/messages/texts?show=${show}&c=${r.conversation_id}`}
                      style={{ textDecoration: "none", padding: "2px 10px" }}
                    >
                      {r.conversation_id === openId ? "Open" : "Answer"}
                    </Link>
                  )}
                  {!canWork ? null : r.spam ? (
                    <NotSpam conversationId={r.conversation_id!} />
                  ) : r.unmatched ? (
                    <UnmatchedActions conversationId={r.conversation_id!} clients={clientList} />
                  ) : r.kind === "sms" ? (
                    <Link
                      className="btn ghost"
                      href={`/clients/${r.client_id}?tab=messages`}
                      style={{ textDecoration: "none", padding: "2px 10px" }}
                    >
                      Open thread
                    </Link>
                  ) : null}
                </div>
              ),
            },
            sort: {
              who: r.client_name ?? r.who ?? "",
              last: r.last_body ?? "",
              when: r.last_message_at ?? "",
            },
            text: `${r.client_name ?? ""} ${r.who ?? ""} ${r.last_body ?? ""} ${r.assigned_name ?? ""} ${r.kind === "web" ? "website chat" : "text"}`,
          }))}
          empty={
            show === "unmatched"
              ? "Everybody who has written in is somebody's."
              : show === "spam"
                ? "Nothing marked spam."
                : show === "mine"
                  ? "No conversation is assigned to you."
                  : show === "web"
                    ? "Nobody has chatted on the website yet."
                    : "Nothing yet."
          }
        />
      </div>

      <p className="lock" style={{ marginTop: 12 }}>
        A client&apos;s texts open on their record, where a reply can be written: texts go out between 8am and 9pm, to
        clients who have agreed to be texted. A website chat is answered here, and becomes part of a client&apos;s record
        as soon as it is matched to one.
      </p>
    </>
  );
}
