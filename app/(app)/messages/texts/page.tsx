import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp, CAN_EDIT_CLIENTS } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";
import { AssignForm, UnmatchedActions, NotSpam } from "./inbox-forms";

/**
 * The texts inbox (Messaging brief, A).
 *
 * Every text conversation the practice has: who it is with, what was last
 * said, who is looking after it, and how much of it you have not read. Texts
 * from a number nobody knows sit at the top until somebody says whose they
 * are, starts a referral, or marks them spam - none of them is ever dropped.
 */
const VIEWS = [
  { key: "open", label: "All open" },
  { key: "mine", label: "Mine" },
  { key: "unmatched", label: "Unmatched" },
  { key: "spam", label: "Spam" },
] as const;

export default async function TextsInboxPage({ searchParams }: { searchParams: Promise<{ show?: string }> }) {
  const me = await requireStaff();
  const { show: rawShow } = await searchParams;
  const show = VIEWS.some((v) => v.key === rawShow) ? rawShow! : "open";
  const canWork = CAN_EDIT_CLIENTS.includes(me.role);

  const supabase = await createClient();
  const [{ data: rows }, { data: staff }, { data: clients }] = await Promise.all([
    supabase.rpc("texts_inbox", { p_show: show }),
    supabase.from("staff").select("id, name").eq("active", true).order("name"),
    supabase.from("clients").select("id, name").neq("status", "Closed").order("name"),
  ]);

  const inbox = rows ?? [];
  const unmatched = inbox.filter((r) => r.unmatched).length;
  const staffList = staff ?? [];
  const clientList = clients ?? [];

  return (
    <>
      <PageHead
        title="Texts"
        context="Every text conversation, and what has not been answered"
        actions={
          <Link className="btn ghost" href="/messages" style={{ textDecoration: "none" }}>
            Staff messages
          </Link>
        }
      />

      <div className="row2 no-print" style={{ justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
        <div className="segmented" role="group" aria-label="Which texts">
          {VIEWS.map((v) => (
            <Link key={v.key} href={`/messages/texts?show=${v.key}`} className={v.key === show ? "on" : undefined}>
              {v.label}
              {v.key === "unmatched" && unmatched > 0 && show !== "unmatched" ? ` (${unmatched})` : ""}
            </Link>
          ))}
        </div>
      </div>

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
                    <b>{r.phone || "(no number)"}</b>
                  )}
                  <div className="lock">
                    {r.client_id ? r.phone : "Not matched to anybody"}
                    {(r.unread ?? 0) > 0 && (
                      <>
                        {" "}
                        <span className="chip gold">{r.unread} unread</span>
                      </>
                    )}
                    {r.client_id && !r.can_text && (
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
              do: !canWork ? null : r.spam ? (
                <NotSpam conversationId={r.conversation_id!} />
              ) : r.unmatched ? (
                <UnmatchedActions conversationId={r.conversation_id!} clients={clientList} />
              ) : (
                <Link className="btn ghost" href={`/clients/${r.client_id}?tab=messages`} style={{ textDecoration: "none", padding: "2px 10px" }}>
                  Open thread
                </Link>
              ),
            },
            sort: {
              who: r.client_name ?? r.phone ?? "",
              last: r.last_body ?? "",
              when: r.last_message_at ?? "",
            },
            text: `${r.client_name ?? ""} ${r.phone ?? ""} ${r.last_body ?? ""} ${r.assigned_name ?? ""}`,
          }))}
          empty={
            show === "unmatched"
              ? "Every number that has texted is somebody's."
              : show === "spam"
                ? "Nothing marked spam."
                : show === "mine"
                  ? "No conversation is assigned to you."
                  : "No texts yet."
          }
        />
      </div>

      <p className="lock" style={{ marginTop: 12 }}>
        A client&apos;s thread opens on their record, where a reply can be written. Texts go out between 8am and 9pm, to
        clients who have agreed to be texted; a message written outside those hours can be scheduled for the morning.
      </p>
    </>
  );
}
