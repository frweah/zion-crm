import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtAgo, fmtStamp } from "@/lib/constants";
import { myMailAccess, resolveMailbox } from "@/lib/mail-access";
import { listMessages, getMessage, listAttachments, MailError, type MessageSummary, type Folder } from "@/lib/mail";
import { PageHead } from "../page-head";
import { RespondForms, DeleteMessage } from "./mail-forms";
import { DragSource, FileToClient, KeepAttachment, Unfile } from "./filing-forms";

/**
 * Mail (Messaging brief, M).
 *
 * The signed-in person's inbox and sent mail, and the shared service@ mailbox
 * for those Exchange has given it - read live from Microsoft with their own
 * token. A message body is shown and never stored.
 *
 * What the CRM keeps is what somebody filed (owner, 23 Oct 2026). Nothing in
 * a mailbox is read, scored or stored unless a person drags it onto a client
 * or picks the name - and then only the log line: subject, date, direction,
 * counterpart, link. A reply on a thread already filed comes with it, because
 * the decision was made when the thread was filed.
 *
 * Nothing about a client's restricted details is shown here - the context
 * beside a matched message is their name, number, stage, who has them and
 * their counselor.
 */
type Params = { box?: string; folder?: string; q?: string; id?: string };

export default async function MailPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const access = await myMailAccess();

  if (!access.ok) {
    return (
      <>
        <PageHead title="Mail" context="Your Outlook mail, inside the CRM" />
        <div className="card">
          <p style={{ margin: 0 }}>{access.message}</p>
          {access.reason !== "not-signed-in" && (
            <p style={{ margin: "12px 0 0" }}>
              <Link className="btn gold" href="/dashboard#outlook" style={{ textDecoration: "none" }}>
                Connect Outlook
              </Link>
            </p>
          )}
        </div>
      </>
    );
  }

  const mailbox = resolveMailbox(access, params.box);
  const folder: Folder = params.folder === "sent" && !mailbox ? "sent" : "inbox";
  const q = (params.q ?? "").trim();
  const boxParam = mailbox || "me";
  const href = (over: Partial<Params>) => {
    const p = new URLSearchParams();
    const merged = { box: boxParam, folder, q, ...over };
    if (merged.box && merged.box !== "me") p.set("box", merged.box);
    if (merged.folder && merged.folder !== "inbox") p.set("folder", merged.folder);
    if (merged.q) p.set("q", merged.q);
    if (merged.id) p.set("id", merged.id);
    const s = p.toString();
    return `/mail${s ? `?${s}` : ""}`;
  };

  const supabase = await createClient();
  const [listResult, clientsResult, counselorsResult, staffResult, syncResult, categoryResult] = await Promise.all([
    mailbox === false
      ? Promise.resolve({ error: "That mailbox is not one you can open here." as string, messages: [] as MessageSummary[] })
      : listMessages(access.token, { mailbox, folder, search: q })
          .then((messages) => ({ error: null as string | null, messages }))
          .catch((e) => ({ error: e instanceof Error ? e.message : "Microsoft did not answer.", messages: [] as MessageSummary[] })),
    supabase.from("clients").select("id, name, client_no, email, stage, assigned_staff_id, counselor_id, status"),
    supabase.from("counselors").select("id, name, email, office"),
    supabase.from("staff").select("id, name"),
    // When this person's mailbox was last swept, which is the question
    // somebody asks of a mail screen that is not their mail client.
    supabase.from("microsoft_sync_state").select("last_run_at").eq("staff_id", access.me.id).maybeSingle(),
    supabase.from("client_file_categories").select("key, label").eq("active", true).order("sort_order"),
  ]);

  // Who an address belongs to, the same matching the sweep logs by.
  const clients = clientsResult.data ?? [];
  const counselors = counselorsResult.data ?? [];
  const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));
  const counselorName = new Map(counselors.map((c) => [c.id, c.name]));
  const clientByEmail = new Map(clients.filter((c) => c.email).map((c) => [c.email!.toLowerCase().trim(), c]));
  const counselorByEmail = new Map(counselors.filter((c) => c.email).map((c) => [c.email!.toLowerCase().trim(), c]));
  const matchOf = (m: MessageSummary) => {
    const all = [m.from, ...m.to, ...m.cc].filter(Boolean).map((a) => a!.address);
    const client = all.map((a) => clientByEmail.get(a)).find(Boolean) ?? null;
    const counselor = all.map((a) => counselorByEmail.get(a)).find(Boolean) ?? null;
    return { client, counselor };
  };

  // The open message, fetched live.
  let open: Awaited<ReturnType<typeof getMessage>> | null = null;
  let openError: string | null = null;
  let attachments: Awaited<ReturnType<typeof listAttachments>> = [];
  let logged: { id: string; client_id: string | null; counselor_id: string | null; filed_how: string | null }[] = [];
  if (params.id && mailbox !== false) {
    try {
      [open, attachments] = await Promise.all([
        getMessage(access.token, mailbox, params.id),
        listAttachments(access.token, mailbox, params.id),
      ]);
      const { data } = await supabase
        .from("mail_log")
        .select("id, client_id, counselor_id, filed_how")
        .eq("graph_message_id", params.id)
        .is("unfiled_at", null);
      logged = data ?? [];
    } catch (e) {
      openError = e instanceof MailError || e instanceof Error ? e.message : "That message could not be opened.";
    }
  }
  const openMatch = open ? matchOf(open) : null;

  // Where this message is filed, if anywhere. The record, not the address
  // match: a message can be matched to a client by address and filed on
  // nobody, which is the whole point of filing being a decision.
  const filedOn = logged.find((l) => l.client_id);
  const filedClient = filedOn ? clients.find((c) => c.id === filedOn.client_id) ?? null : null;

  // Who a message can be dropped on: the caseload, closed clients last,
  // because filing a reply onto somebody closed is rarer than onto somebody
  // being worked with and the list is read from the top.
  const targets = clients
    .filter((c) => c.status !== "Deleted")
    .map((c) => ({ id: c.id, name: c.name, client_no: c.client_no, stage: c.stage ?? "" }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const categories = (categoryResult.data ?? []).map((c) => c.key);
  const lastSync = syncResult.data?.last_run_at ?? null;

  const boxes: { key: string; label: string; folder: Folder }[] = [
    { key: "me", label: "Inbox", folder: "inbox" },
    { key: "me", label: "Sent", folder: "sent" },
    ...access.sharedMailboxes.map((m) => ({ key: m.address, label: m.label || m.address, folder: "inbox" as Folder })),
  ];

  return (
    <>
      <PageHead
        title="Mail"
        context={
          (mailbox ? `The shared mailbox ${mailbox}` : `Your Outlook mail, ${access.email}`) +
          ` · synced ${fmtAgo(lastSync)}`
        }
        actions={
          access.canSend ? (
            <Link className="btn gold" href="/mail/compose" style={{ textDecoration: "none" }}>
              New message
            </Link>
          ) : (
            <a className="btn ghost" href="/api/auth/microsoft/start?send=1">
              Turn sending on
            </a>
          )
        }
      />

      {!access.canSend && (
        <div className="alert" style={{ marginBottom: 12 }}>
          You can read your mail here. Sending and deleting from the CRM need one reconnect of your Outlook, which asks
          Microsoft to let the CRM send as you, or move a message to your Deleted Items, when - and only when - you
          press the button.{" "}
          <a href="/api/auth/microsoft/start?send=1" style={{ color: "inherit" }}>
            <b>Turn sending on</b>
          </a>
          .
        </div>
      )}

      <div className="row2 no-print" style={{ justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
        <div className="segmented" role="group" aria-label="Mailbox">
          {boxes.map((b) => {
            const on = (b.key === "me" ? mailbox === null : mailbox === b.key) && b.folder === folder;
            return (
              <Link key={`${b.key}-${b.folder}`} href={href({ box: b.key, folder: b.folder, q: "", id: undefined })} className={on ? "on" : undefined}>
                {b.label}
              </Link>
            );
          })}
        </div>
        <form action="/mail" className="row2" style={{ gap: 6 }}>
          {mailbox && <input type="hidden" name="box" value={mailbox} />}
          <input id="mail-search" type="search" name="q" defaultValue={q} placeholder="Search this mailbox" aria-label="Search this mailbox" style={{ maxWidth: 260 }} />
          <button className="btn ghost" type="submit">
            Search
          </button>
        </form>
      </div>

      <div className="mail-layout">
        <div className="card" style={{ padding: 0 }}>
          {listResult.error ? (
            <p className="empty" style={{ padding: 16 }}>
              {listResult.error}
            </p>
          ) : listResult.messages.length === 0 ? (
            <p className="empty" style={{ padding: 16 }}>
              {q ? `Nothing matches “${q}”.` : "Nothing here."}
            </p>
          ) : (
            <ul className="mail-list">
              {listResult.messages.map((m) => {
                const { client, counselor } = matchOf(m);
                const who = folder === "sent" ? m.to.map((a) => a.name || a.address).join(", ") : m.from?.name || m.from?.address || "";
                return (
                  <li key={m.id}>
                    <DragSource id={m.id}>
                    <Link href={href({ id: m.id })} className={"mail-row" + (m.id === params.id ? " on" : "") + (m.isRead ? "" : " unread")} aria-current={m.id === params.id ? "true" : undefined}>
                      <span className="mail-who">
                        {!m.isRead && <span className="chip gold">New</span>} {who}
                      </span>
                      <span className="mail-when">{fmtStamp(m.receivedAt)}</span>
                      <span className="mail-subject">{m.subject}</span>
                      <span className="lock mail-preview">{m.preview}</span>
                      {(client || counselor) && (
                        <span className="mail-tags">
                          {client && <span className="chip ok">Client: {client.name}</span>}
                          {counselor && <span className="chip">Counselor: {counselor.name}</span>}
                        </span>
                      )}
                    </Link>
                    </DragSource>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        <div style={{ display: "grid", gap: 16, alignItems: "start" }}>
          {openError && <div className="alert bad">{openError}</div>}
          {!open && !openError && (
            <div className="card">
              <p className="empty" style={{ margin: 0 }}>
                Choose a message to read it, live from Outlook and kept in the CRM only if you file it.
              </p>
            </div>
          )}

          {/* Filing, beside the message rather than inside it: the same panel
              is the drop target for anything dragged out of the list, so it
              has to be there whether a message is open or not. */}
          <FileToClient
            clients={targets}
            box={boxParam}
            selected={open?.id ?? null}
            selectedSubject={open?.subject ?? ""}
          />

          {filedClient && filedOn && (
            <div className="card">
              <div className="row2" style={{ justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
                <span>
                  Filed on{" "}
                  <Link href={`/clients/${filedClient.id}`}>
                    <b>{filedClient.name}</b>
                  </Link>
                  <span className="lock">
                    {" "}
                    {filedOn.filed_how === "auto"
                      ? "by the sync, on a thread somebody filed"
                      : filedOn.filed_how === "sent"
                        ? "because the practice sent it"
                        : "by hand"}
                  </span>
                </span>
                <Unfile mailId={filedOn.id} clientId={filedClient.id} clientName={filedClient.name} />
              </div>
            </div>
          )}
          {open && (
            <article className="card">
              <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
                <h2 className="h2" style={{ marginBottom: 6 }}>
                  {open.subject}
                </h2>
                {mailbox === null && access.canDelete && (
                  <DeleteMessage messageId={open.id} back={href({ id: undefined })} />
                )}
              </div>
              <p className="lock" style={{ margin: "0 0 12px" }}>
                From <b>{open.from?.name || open.from?.address}</b> {open.from?.name ? `<${open.from.address}>` : ""} ·{" "}
                {fmtStamp(open.receivedAt)}
                <br />
                To {open.to.map((a) => a.address).join(", ") || "—"}
                {open.cc.length > 0 && <> · Cc {open.cc.map((a) => a.address).join(", ")}</>}
              </p>

              {(openMatch?.client || openMatch?.counselor) && (
                <aside className="mail-context">
                  {openMatch.client && (
                    <div>
                      <div className="label">Client</div>
                      <Link href={`/clients/${openMatch.client.id}`}>
                        <b>{openMatch.client.name}</b>
                      </Link>
                      {openMatch.client.client_no ? ` · #${openMatch.client.client_no}` : ""} · {openMatch.client.stage}
                      <div className="lock">
                        {openMatch.client.assigned_staff_id ? `With ${staffName.get(openMatch.client.assigned_staff_id) ?? "—"}` : "Nobody assigned"}
                        {openMatch.client.counselor_id ? ` · counselor ${counselorName.get(openMatch.client.counselor_id) ?? "—"}` : ""}
                      </div>
                    </div>
                  )}
                  {openMatch.counselor && (
                    <div>
                      <div className="label">Counselor</div>
                      <Link href={`/counselors/${openMatch.counselor.id}`}>
                        <b>{openMatch.counselor.name}</b>
                      </Link>
                      {openMatch.counselor.office ? ` · ${openMatch.counselor.office}` : ""}
                    </div>
                  )}
                  <div className="lock">
                    {filedClient
                      ? "On the record - subject, date, direction and link, never the text."
                      : "Not on anybody's record. File it to keep it."}
                  </div>
                </aside>
              )}

              <div className="mail-body">{open.bodyText}</div>

              {attachments.length > 0 && (
                <div style={{ marginTop: 14 }}>
                  <div className="label" style={{ marginBottom: 6 }}>
                    Attachments
                  </div>
                  <div style={{ display: "grid", gap: 8 }}>
                    {attachments.map((a) => (
                      <div key={a.id} className="row2" style={{ gap: 6, flexWrap: "wrap", alignItems: "center" }}>
                        <a
                          className="btn ghost"
                          href={`/api/mail/attachment?${new URLSearchParams({ box: boxParam, m: open!.id, a: a.id, n: a.name })}`}
                        >
                          {a.name} <span className="lock">({Math.max(1, Math.round(a.size / 1024))} KB)</span>
                        </a>
                        {/* Only off a filed message: an attachment belongs to
                            a client's record, and a message nobody has filed
                            is not on one. */}
                        {filedClient && (
                          <KeepAttachment
                            messageId={open!.id}
                            attachmentId={a.id}
                            name={a.name}
                            clientId={filedClient.id}
                            box={boxParam}
                            categories={categories}
                          />
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              )}

              <RespondForms messageId={open.id} box={boxParam} canSend={access.canSend} />
              {open.webLink && (
                <p className="lock" style={{ margin: "12px 0 0" }}>
                  <a href={open.webLink} target="_blank" rel="noopener noreferrer">
                    Open in Outlook
                  </a>
                </p>
              )}
            </article>
          )}
        </div>
      </div>
    </>
  );
}
