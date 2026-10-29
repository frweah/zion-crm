import "server-only";

import { createClient } from "@/lib/supabase/server";

/**
 * Filing mail on a client — the facts, and only the facts.
 *
 * This is the one module that writes to the database about an email, and it
 * is deliberately the one module that cannot read one. It does not import
 * `lib/mail` or `lib/mail-send`, so nothing here has ever held a message
 * body, and none of the types below has anywhere to put one.
 *
 * That split is the whole rule. Before the practice filed mail on purpose
 * (0233) the rule could be the blunter "nothing that touches mail touches the
 * database", and `scripts/check-mail.mjs` said exactly that. Filing made that
 * untrue - the owner asked for a sent message to land on the client and in
 * the contact log - so the check now holds the thing the blunt rule was
 * protecting: a body exists only where there is no write, and a write happens
 * only where there is no body. The database holds the other end: no table has
 * a column a body could go in (supabase/verify_mail.sql).
 *
 * What gets stored, here and nowhere else: the message id, its thread, the
 * subject, when it was sent, which way it went, who it was with, and the
 * Outlook link. Somebody reading a filed message reads it from Outlook
 * through that link, or through the Mail screen, which fetches it live.
 */

/** A message, as the CRM records it. There is no body field, on purpose. */
export type MessageFacts = {
  /** Graph's id for the message, in the mailbox named below. */
  id: string;
  /** Graph's conversation id, which is how a reply finds its way home. */
  conversation: string;
  subject: string;
  /** ISO. */
  sent_at: string;
  direction: "Incoming" | "Outgoing";
  /** The other person's address. */
  counterpart: string;
  web_link: string;
  /** A shared mailbox's address, or "" for the signed-in person's own. */
  mailbox: string;
};

export type FilingResult = { filed: number; moved: number };

/**
 * File messages, or a whole thread, onto a client.
 *
 * The database decides whether it is allowed and who did it; this hands over
 * the facts and passes the refusal back in the words the database used.
 */
export async function fileOnClient(
  clientId: string,
  messages: MessageFacts[],
  thread?: string | null,
  how: "by hand" | "sent" = "by hand",
): Promise<{ error: string | null; result?: FilingResult }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("file_mail_to_client", {
    p_client: clientId,
    p_messages: messages as unknown as never,
    p_thread: thread ?? null,
    p_how: how,
  });
  if (error) return { error: error.message };
  const row = (data as unknown as FilingResult[] | null)?.[0];
  return { error: null, result: { filed: row?.filed ?? 0, moved: row?.moved ?? 0 } };
}

/** Take one filed message off a client, with a reason. The mailbox keeps it. */
export async function unfileFromClient(
  mailLogId: string,
  reason: string,
): Promise<{ error: string | null; subject?: string }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("unfile_mail", { p_id: mailLogId, p_reason: reason });
  if (error) return { error: error.message };
  const row = (data as unknown as { subject: string }[] | null)?.[0];
  return { error: null, subject: row?.subject ?? "" };
}

/** Mark a thread restricted on this client, or let it back out. */
export async function setThreadRestricted(
  conversation: string,
  clientId: string,
  restricted: boolean,
): Promise<{ error: string | null; changed?: number }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_mail_restricted", {
    p_conversation: conversation,
    p_client: clientId,
    p_restricted: restricted,
  });
  if (error) return { error: error.message };
  return { error: null, changed: Number(data ?? 0) };
}

/**
 * The line in the contact log for a message the practice sent.
 *
 * Who sent it, who it went to, what it was about and when - which is what the
 * log is for. The words of the message are not here and are not anywhere: the
 * subject is the practice's own one-line description of what it wrote, which
 * is the same thing the log has always carried for a phone call.
 */
export async function logSentOnClient(fields: {
  clientId: string;
  staffId: string;
  subject: string;
  to: string[];
  cc: string[];
}): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const recipients =
    `To ${fields.to.join(", ")}` + (fields.cc.length ? ` · cc ${fields.cc.join(", ")}` : "");
  const { error } = await supabase.from("contact_log").insert({
    client_id: fields.clientId,
    staff_id: fields.staffId,
    date: new Date().toISOString().slice(0, 10),
    method: "Email sent",
    topic: fields.subject,
    outcome: recipients,
  });
  return { error: error?.message ?? null };
}

export type Recipient = {
  address: string;
  label: string;
  /** What they are to this client, which is also the sort order on screen. */
  kind: "counselor" | "billing" | "client" | "staff";
};

/**
 * Who this client's mail can be addressed to, from the record.
 *
 * Picked rather than typed, because an address typed into a box is the one
 * way a client's business reaches somebody it was not meant to. Anything else
 * still goes in Cc by hand - except the client themselves, who can only be
 * written to at the address on their own record (checked where the message is
 * sent).
 */
export async function recipientsForClient(clientId: string): Promise<{
  recipients: Recipient[];
  clientAddress: string;
  clientName: string;
}> {
  const supabase = await createClient();
  const { data: client } = await supabase
    .from("clients")
    .select("name, email, counselor_id, assigned_staff_id")
    .eq("id", clientId)
    .maybeSingle();
  if (!client) return { recipients: [], clientAddress: "", clientName: "" };

  const [counselor, staff, office] = await Promise.all([
    client.counselor_id
      ? supabase.from("counselors").select("name, email").eq("id", client.counselor_id).maybeSingle()
      : Promise.resolve({ data: null }),
    client.assigned_staff_id
      ? supabase.from("staff").select("name, email").eq("id", client.assigned_staff_id).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("client_billing_office").select("billing_office_id").eq("client_id", clientId).maybeSingle(),
  ]);

  let billing: { name: string; address: string } | null = null;
  if (office.data?.billing_office_id) {
    const { data } = await supabase
      .from("billing_offices")
      .select("name, billing_email")
      .eq("id", office.data.billing_office_id)
      .maybeSingle();
    if (data?.billing_email) billing = { name: data.name, address: data.billing_email };
  }

  const recipients: Recipient[] = [];
  if (counselor.data?.email) {
    recipients.push({ address: counselor.data.email, label: `${counselor.data.name} — counselor`, kind: "counselor" });
  }
  if (billing) recipients.push({ address: billing.address, label: `${billing.name} — billing`, kind: "billing" });
  if (client.email) recipients.push({ address: client.email, label: `${client.name} — the client`, kind: "client" });
  if (staff.data?.email) {
    recipients.push({ address: staff.data.email, label: `${staff.data.name} — assigned`, kind: "staff" });
  }

  return {
    recipients: recipients.filter((r, i, all) => all.findIndex((o) => o.address.toLowerCase() === r.address.toLowerCase()) === i),
    clientAddress: (client.email ?? "").toLowerCase(),
    clientName: client.name,
  };
}

/** A document on the client's record, offered as something to attach. */
export type AttachableDocument = {
  id: string;
  filename: string;
  category: string;
  document_date: string | null;
  size_bytes: number | null;
  restricted: boolean;
};

/**
 * The client's documents, as things a message can carry.
 *
 * Read through `client_documents`, which is the view that redacts a
 * restricted document rather than hiding it - so the list leaves out exactly
 * the ones this person may not open, and a restricted document somebody can
 * see is theirs to send.
 */
export async function documentsForClient(clientId: string): Promise<AttachableDocument[]> {
  const supabase = await createClient();
  const { data } = await supabase
    .from("client_documents")
    .select("id, filename, category, document_date, size_bytes, restricted, can_open")
    .eq("client_id", clientId)
    .order("document_date", { ascending: false })
    .limit(200);
  return (data ?? [])
    .filter((d) => d.can_open)
    .map((d) => ({
      id: d.id as string,
      filename: (d.filename as string) ?? "",
      category: (d.category as string) ?? "",
      document_date: (d.document_date as string | null) ?? null,
      size_bytes: (d.size_bytes as number | null) ?? null,
      restricted: Boolean(d.restricted),
    }));
}

/** Where a document's bytes live, and what it is called. No bytes read here. */
export async function documentPaths(
  clientId: string,
  ids: string[],
): Promise<{ id: string; filename: string; storage_path: string; mime_type: string; size_bytes: number }[]> {
  if (ids.length === 0) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from("client_documents")
    .select("id, filename, storage_path, mime_type, size_bytes, can_open")
    .eq("client_id", clientId)
    .in("id", ids);
  return (data ?? [])
    .filter((d) => d.can_open && d.storage_path)
    .map((d) => ({
      id: d.id as string,
      filename: (d.filename as string) ?? "file",
      storage_path: d.storage_path as string,
      mime_type: (d.mime_type as string) ?? "application/octet-stream",
      size_bytes: Number(d.size_bytes ?? 0),
    }));
}

/**
 * Which of these addresses belong to a client who is not this one.
 *
 * The owner's rule is that a client is written to at the address on their own
 * record. The way that goes wrong is not somebody inventing an address - it
 * is picking the right-looking one for the wrong person, two clients with the
 * same surname, or a counselor's record carrying a client's address. So the
 * question asked is the useful one: is this address a client's, and is it
 * this client's.
 */
export async function addressesBelongingToAnotherClient(
  addresses: string[],
  thisClientAddress: string,
): Promise<string[]> {
  const candidates = [...new Set(addresses.map((a) => a.toLowerCase().trim()).filter(Boolean))]
    .filter((a) => a !== thisClientAddress.toLowerCase().trim());
  if (candidates.length === 0) return [];

  const supabase = await createClient();
  const { data } = await supabase.from("clients").select("email").in("email", candidates);
  const taken = new Set((data ?? []).map((r) => (r.email ?? "").toLowerCase()));
  return candidates.filter((a) => taken.has(a));
}

/**
 * Keep an attachment on the client's record, as a document.
 *
 * This is the one place bytes from a mailbox become something the practice
 * holds, and it is deliberate: the owner asked for an attachment on a filed
 * message to be saveable into the client's documents, under the same rule as
 * any other document. A message body is still never stored - and could not
 * be, because no column exists for one. An attachment somebody chose to keep
 * is a document, which the practice has always kept.
 *
 * "The one-document rule" is the fingerprint index: this client cannot have
 * the same bytes twice, so saving the same attachment again says so instead
 * of making a second copy of the same scan.
 */
export async function keepAttachmentOnClient(file: {
  clientId: string;
  filename: string;
  mime: string;
  data: Buffer;
  category: string;
  restricted: boolean;
  note: string;
}): Promise<{ error: string | null; ok: string | null; id: string | null }> {
  const supabase = await createClient();
  const { createHash, randomUUID } = await import("node:crypto");
  const sha256 = createHash("sha256").update(file.data).digest("hex");

  const dot = file.filename.lastIndexOf(".");
  const ext = dot > 0 ? file.filename.slice(dot + 1).toLowerCase() : "";
  const path = `clients/${file.clientId}/${randomUUID()}${ext ? `.${ext}` : ""}`;

  const put = await supabase.storage
    .from("client-files")
    .upload(path, file.data, { contentType: file.mime || "application/octet-stream" });
  if (put.error) {
    return { error: `${file.filename} was not kept: ${put.error.message}`, ok: null, id: null };
  }

  // The row's id comes back because a generated document has something
  // pointing at it: a signed monthly report records which attachment it was
  // signed as, and a report whose PDF it cannot name is a report nobody can
  // check against what was sent.
  const { data: row, error } = await supabase.from("attachments").insert({
    client_id: file.clientId,
    storage_path: path,
    filename: file.filename,
    mime_type: file.mime,
    size_bytes: file.data.length,
    category: file.category,
    restricted: file.restricted,
    document_date: new Date().toISOString().slice(0, 10),
    sha256,
    note: file.note,
  }).select("id").single();

  if (error) {
    // Unrecorded is invisible: nobody could find it and nobody could delete
    // it, so it does not stay in the bucket.
    await supabase.storage.from("client-files").remove([path]);
    const twice = error.code === "23505" && /attachments_one_copy_per_client/.test(error.message);
    return {
      error: twice
        ? "This client already has that exact file on their record. Nothing was added."
        : error.message,
      ok: null,
      id: null,
    };
  }

  return { error: null, ok: `${file.filename} is on the record.`, id: row.id };
}

/**
 * Whether this message may be the sending of a signed monthly report.
 *
 * Asked before anything leaves the building, and asked here rather than on
 * the screen because the screen is a form somebody can post whatever they
 * like to. Three things have to be true: the report belongs to this client,
 * the practice has signed it, and the document attached is the PDF it was
 * signed as.
 *
 * The third is the one that matters. A report marked Sent whose counselor
 * received some other document is worse than a report never sent, because
 * the record then says the counselor was told something they were not. The
 * brief's "counselors only ever receive a signed report" and 34 CFR 361.38
 * are the same rule read from two directions.
 */
export async function reportReadyToSend(
  clientId: string,
  reportId: string,
  documents: string[],
): Promise<{ error: string | null; report: { id: string; month: string } | null }> {
  const supabase = await createClient();
  const { data: row } = await supabase
    .from("client_monthly_reports")
    .select("id, month, status, pdf_attachment_id")
    .eq("id", reportId)
    .eq("client_id", clientId)
    .maybeSingle();

  if (!row) return { error: "That report is not on this client's record.", report: null };
  if (row.status === "Sent") {
    return { error: "That report has already gone to the counselor.", report: null };
  }
  if (row.status !== "Signed") return { error: "Sign the report before sending it.", report: null };
  if (!row.pdf_attachment_id || !documents.includes(row.pdf_attachment_id)) {
    return { error: "Attach the signed report itself before sending it.", report: null };
  }

  return { error: null, report: { id: row.id, month: row.month } };
}

/**
 * The report is sent, because it has been.
 *
 * Called after Microsoft accepted the message and never before. A row that
 * said Sent first would be a report the practice believed the counselor had,
 * which is the thing this whole feature exists to stop.
 */
export async function markReportSent(fields: {
  reportId: string;
  staffId: string;
  to: string[];
  cc: string[];
  at: string | null;
}): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const sentTo = fields.cc.length
    ? `${fields.to.join(", ")} (copy to ${fields.cc.join(", ")})`
    : fields.to.join(", ");

  const { error } = await supabase
    .from("client_monthly_reports")
    .update({
      status: "Sent",
      sent_at: fields.at ?? new Date().toISOString(),
      sent_by: fields.staffId,
      sent_to: sentTo,
    })
    .eq("id", fields.reportId);

  return { error: error ? `the report was not marked sent: ${error.message}` : null };
}
