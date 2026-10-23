import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";
import { myMailAccess } from "@/lib/mail-access";
import { RestrictThread } from "../../mail/filing-forms";
import { Unfile } from "../../mail/filing-forms";

/**
 * The mail filed on this client (owner, 23 Oct 2026).
 *
 * Threads, newest first, not messages: a conversation is one thing to a
 * person reading a record, and six rows saying "Re: Re: Re:" are the same
 * thing six times. The newest message in each thread gives the row its date
 * and its subject.
 *
 * Nothing here is the message. The body and the attachments are read live
 * from Outlook when somebody opens one, which is why the link goes to Mail
 * rather than to a copy kept here - there is no copy. A message in somebody
 * else's mailbox says so, and offers Outlook's own link instead.
 *
 * A restricted thread keeps its row and loses its words, the same way a
 * restricted document does: hiding it entirely teaches people the record is
 * complete when it is not.
 */
/**
 * The four ways a message is here, in one word each.
 *
 * Three of them mean somebody or something in the practice put it on this
 * client deliberately. **Matched** does not: the sweep recognised an address
 * in service@ and wrote a line, and nobody read it or chose it. That is the
 * distinction the owner asked to be visible, so it is a word on the row
 * rather than a sentence underneath it.
 */
const STATE: Record<string, string> = {
  sent: "Sent",
  "by hand": "Filed",
  auto: "Reply",
  matched: "Matched",
};

type Row = {
  id: string;
  conversation_id: string;
  graph_message_id: string;
  sent_at: string;
  direction: string;
  restricted: boolean;
  filed_how: string | null;
  filed_by_name: string | null;
  can_open: boolean;
  subject: string;
  counterpart_email: string;
  web_link: string;
  mailbox_address: string;
};

export async function MailSection({ clientId, clientName }: { clientId: string; clientName: string }) {
  const supabase = await createClient();
  const [{ data }, { data: mayRestrict }, access] = await Promise.all([
    supabase
      .from("client_mail")
      .select(
        "id, conversation_id, graph_message_id, sent_at, direction, restricted, filed_how, filed_by_name, can_open, subject, counterpart_email, web_link, mailbox_address",
      )
      .eq("client_id", clientId)
      .order("sent_at", { ascending: false })
      .limit(300),
    supabase.rpc("can_see_restricted", { p_client_id: clientId }),
    myMailAccess(),
  ]);

  const rows = (data ?? []) as Row[];
  const mine = access.ok ? access.email.toLowerCase() : "";
  const sharedIAccess = new Set(access.ok ? access.sharedMailboxes.map((m) => m.address.toLowerCase()) : []);

  // One row per thread, the newest message standing for it, and a count so a
  // long exchange says it is a long exchange.
  const threads = new Map<string, { head: Row; count: number }>();
  for (const row of rows) {
    const key = row.conversation_id || row.id;
    const seen = threads.get(key);
    if (seen) seen.count += 1;
    else threads.set(key, { head: row, count: 1 });
  }

  return (
    <section style={{ marginBottom: 20 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
        <h2 className="h2">Mail</h2>
        <Link className="btn ghost" href={`/mail/compose?client=${clientId}`} style={{ textDecoration: "none" }}>
          Write
        </Link>
      </div>

      {threads.size === 0 ? (
        <p className="empty">Nothing filed yet — write from here, or file a message on Mail</p>
      ) : (
        <div className="card" style={{ padding: "4px 14px" }}>
          {[...threads.values()].map(({ head, count }) => {
            // Whose mailbox it sits in decides whether this person can open
            // it here at all. Outlook's own link is the fallback, and for
            // somebody without access to that mailbox it is the honest answer.
            const inMyMailbox = head.mailbox_address === "" || head.mailbox_address.toLowerCase() === mine;
            const inASharedOne = sharedIAccess.has(head.mailbox_address.toLowerCase());
            const readable = head.can_open && (inMyMailbox || inASharedOne);
            const box = inMyMailbox ? "me" : head.mailbox_address;

            return (
              <div key={head.conversation_id || head.id} className="mail-thread">
                <div className="row2" style={{ justifyContent: "space-between", gap: 10, alignItems: "baseline" }}>
                  <span>
                    {readable ? (
                      <Link href={`/mail?box=${encodeURIComponent(box)}&id=${encodeURIComponent(head.graph_message_id)}`}>
                        <b>{head.subject || "(no subject)"}</b>
                      </Link>
                    ) : (
                      <b>{head.can_open ? head.subject || "(no subject)" : "Restricted"}</b>
                    )}
                    {count > 1 && <span className="lock"> · {count} messages</span>}
                  </span>
                  <span className="row2" style={{ gap: 6, alignItems: "baseline" }}>
                    {/* How it got here, as a word rather than a sentence to
                        read: somebody scanning a record wants to know which
                        of these is the practice's own correspondence and
                        which is a line the sweep wrote (owner, 23 Oct 2026).
                        "Matched" is the one that means nobody chose it. */}
                    <span className={"chip" + (head.filed_how === "matched" ? "" : " ok")}>
                      {STATE[head.filed_how ?? "matched"] ?? "Matched"}
                    </span>
                    <span className="lock">{fmtStamp(head.sent_at)}</span>
                  </span>
                </div>

                <div className="lock">
                  {head.can_open ? (
                    <>
                      {head.direction === "Incoming" ? "From" : "To"} {head.counterpart_email || "—"}
                      {" · "}
                      {head.filed_how === "sent"
                        ? `sent by ${head.filed_by_name || "the practice"}`
                        : head.filed_how === "auto"
                          ? "a reply on a thread somebody filed"
                          : head.filed_how === "matched"
                            ? "the sync recognised the address — nobody filed it"
                            : `filed by ${head.filed_by_name || "somebody"}`}
                      {!readable && head.mailbox_address && ` · in ${head.mailbox_address}`}
                      {!readable && !head.mailbox_address && " · in a colleague's mailbox"}
                    </>
                  ) : (
                    "Restricted. Admin, Intake & Client Reports, or this client's assigned staff member can read it."
                  )}
                </div>

                <div className="row2" style={{ gap: 6, flexWrap: "wrap", marginTop: 4 }}>
                  {head.restricted && <span className="chip warn">Restricted</span>}
                  {!readable && head.can_open && head.web_link && (
                    <a className="btn ghost" href={head.web_link} target="_blank" rel="noopener noreferrer">
                      Open in Outlook
                    </a>
                  )}
                  {mayRestrict === true && head.conversation_id && (
                    <RestrictThread
                      conversation={head.conversation_id}
                      clientId={clientId}
                      restricted={head.restricted}
                    />
                  )}
                  {head.can_open && <Unfile mailId={head.id} clientId={clientId} clientName={clientName} />}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
