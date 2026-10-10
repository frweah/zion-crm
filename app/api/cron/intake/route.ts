import { NextResponse, type NextRequest } from "next/server";
import { createHash } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { sweepAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";
import { sendEmail, emailConfigured } from "@/lib/email";
import { readDocument } from "@/lib/read-document";
import { classifyDocument } from "@/lib/classify-document";
import { parseAuthorizationText } from "@/lib/authorization-parse";
import { parseReferralText } from "@/lib/referral-parse";
import { INBOX_BUCKET, STORAGE_MAX_BYTES, inboxStoragePath } from "@/lib/inbox-storage";
import { INTAKE_MAILBOX } from "@/lib/intake-source";
import {
  readIntakeMailbox,
  type IntakeHandler,
  type IntakeMessage,
  type IntakePdf,
} from "@/lib/intake-mail";

/**
 * Intake: what arrived at service@, filed.
 *
 * Email → client → authorization → notifications, with nobody in the loop
 * except to confirm (Intake Automation Brief, 10 Oct 2026).
 *
 * Three things happen and each is the other side of a boundary from the other
 * two, which is the only reason this is readable at all:
 *
 *   lib/intake-mail.ts holds the mail token. It reads service@, hands over
 *   each PDF, and thanks the counselor when told to. It never sees the
 *   database - the separation lib/sync.ts keeps for the nightly sweep, and the
 *   one scripts/check-mail.mjs holds every file that touches mail to.
 *
 *   This route holds the database client. For each PDF it reads the document
 *   with the one reader, stores it the way the agent stores one, and asks the
 *   rules what it is.
 *
 *   The rules are in the database (0182). They create the client, attach the
 *   document, raise the task and write the notification in one transaction,
 *   and hand back the words to email. They are the part that can be wrong in a
 *   way nobody notices, so they are the part tested without a mailbox
 *   (verify_the_intake.sql).
 *
 * Only service@ is read, and only utah.gov senders are acted on. Everything
 * else is left alone, with the skip logged so somebody can answer "did the
 * counselor's email arrive" without guessing.
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/intake
 */
export const dynamic = "force-dynamic";
export const maxDuration = 300;

type Supabase = ReturnType<typeof createAdminClient>;

/** The decision for one PDF, taken by the rules in the database. */
type Filed = {
  action: string;
  client_id: string | null;
  authorization_id?: string | null;
  notify: { name: string; email: string | null; message: string }[];
  reply: boolean;
  candidates?: string;
};

/**
 * The token that reaches service@.
 *
 * Two ways it can be connected and both are read, because which one is true is
 * an administrative fact that may change without anybody telling this code: as
 * somebody's own mailbox (it is Francis's Microsoft connection today), or as a
 * shared mailbox somebody has been given access to. Either way the token
 * belongs to a person and reaches exactly as far as Exchange lets them.
 */
async function serviceMailbox(admin: Supabase) {
  const { data: shared } = await admin
    .from("shared_mailboxes")
    .select("address, connected_by")
    .ilike("address", INTAKE_MAILBOX)
    .eq("active", true)
    .maybeSingle();
  if (shared?.connected_by) {
    return { staffId: shared.connected_by, mailbox: shared.address as string | null };
  }

  const { data: own } = await admin
    .from("microsoft_connections")
    .select("staff_id, microsoft_email")
    .ilike("microsoft_email", INTAKE_MAILBOX)
    .maybeSingle();
  // Its own connection: Graph calls go to /me, which *is* service@.
  if (own?.staff_id) return { staffId: own.staff_id, mailbox: null };

  return null;
}

export async function POST(request: NextRequest) {
  return handle(request);
}

export async function GET(request: NextRequest) {
  return handle(request);
}

async function handle(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  const provided =
    request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ??
    request.nextUrl.searchParams.get("secret");
  if (!secret || provided !== secret) {
    return NextResponse.json({ error: "Not authorised." }, { status: 401 });
  }

  const admin = createAdminClient();
  const where = await serviceMailbox(admin);
  if (!where) {
    return NextResponse.json(
      { error: `Nobody is connected to read ${INTAKE_MAILBOX}, so nothing was read.` },
      { status: 503 },
    );
  }

  const { tokens } = sweepAccess(admin, where.staffId);
  const bundle = await tokens.read();
  if (!bundle) {
    return NextResponse.json(
      { error: `The connection that reads ${INTAKE_MAILBOX} is no longer there.` },
      { status: 503 },
    );
  }
  const token = await ensureFreshToken(bundle, tokens.write);

  const looked: Record<string, unknown>[] = [];
  const emailed: string[] = [];

  const handler: IntakeHandler = {
    async skipped(message, decision, detail) {
      await admin.rpc("intake_record_mail", {
        p_message: message.id,
        p_from: message.from,
        p_subject: message.subject,
        p_received: message.receivedAt,
        p_decision: decision,
        p_detail: detail,
      });
      looked.push({ from: message.from, decision });
    },

    async pdf(message, pdf) {
      const filed = await onePdf(admin, message, pdf);
      looked.push({ from: message.from, filename: pdf.name, ...filed.summary });

      // The email half of each notification. The words come from the database
      // with the notification, so the bell, My day and the mail all carry the
      // same sentence.
      for (const who of filed.notify) {
        if (!who.email || !emailConfigured()) continue;
        await sendEmail({
          to: who.email,
          subject: "Zion CRM — intake",
          text: `${who.message}\n\nFiled automatically from ${INTAKE_MAILBOX}.`,
        });
        emailed.push(who.email);
      }
      return { reply: filed.reply };
    },

    async failed(message, pdf, detail) {
      await admin.rpc("intake_record_mail", {
        p_message: message.id,
        p_from: message.from,
        p_subject: message.subject,
        p_received: message.receivedAt,
        p_decision: "unreadable",
        p_detail: detail.slice(0, 400),
      });
      looked.push({ from: message.from, filename: pdf.name, decision: "unreadable", detail });
    },
  };

  const run = await readIntakeMailbox(token, where.mailbox, handler);

  return NextResponse.json({ mailbox: INTAKE_MAILBOX, ...run, emailed, looked });
}

/** One PDF: read it, keep it, and let the rules decide what it is. */
async function onePdf(
  admin: Supabase,
  message: IntakeMessage,
  pdf: IntakePdf,
): Promise<{ reply: boolean; notify: Filed["notify"]; summary: Record<string, unknown> }> {
  if (pdf.bytes.byteLength > STORAGE_MAX_BYTES) {
    throw new Error(`${pdf.name} is larger than the ${STORAGE_MAX_BYTES} byte limit`);
  }

  const sha256 = createHash("sha256").update(pdf.bytes).digest("hex");

  // ── read it, with the one reader ───────────────────────────
  const reading = await readDocument(pdf.bytes, admin, null);
  const classification = classifyDocument(reading.text);

  // ── keep it, the way the agent keeps one ───────────────────
  const storagePath = inboxStoragePath(sha256);
  const { error: uploadError } = await admin.storage
    .from(INBOX_BUCKET)
    .upload(storagePath, pdf.bytes, { contentType: "application/pdf", upsert: true });
  if (uploadError) throw new Error(`not stored: ${uploadError.message}`);

  // The fingerprint is unique, so a document that arrives twice is one
  // document - which is what makes a re-sent referral a re-send rather than a
  // second record.
  const { data: existing } = await admin
    .from("inbox_documents")
    .select("id")
    .eq("sha256", sha256)
    .maybeSingle();

  let docId = existing?.id ?? null;
  if (!docId) {
    const { data: row, error } = await admin
      .from("inbox_documents")
      .insert({
        sha256,
        folder_name: "service@ mail",
        relative_path: `mail/${message.id}/${pdf.name}`,
        filename: pdf.name,
        size_bytes: pdf.bytes.byteLength,
        kind: reading.kind,
        parsed: reading.parsed,
        proposal: reading.proposal,
        storage_path: storagePath,
      })
      .select("id")
      .single();
    if (error) throw new Error(error.message);
    docId = row.id;
  }

  // ── and let the rules decide ───────────────────────────────
  const scanned = reading.kind === "Unreadable" || Boolean(reading.ocr);
  let filed: Filed;

  if (classification.referral) {
    const read = parseReferralText(reading.text);
    const name = read.fields.clientName?.value ?? "";
    // The one document that may create a client, so a name read off the wrong
    // line would create one. Nothing is filed without a name.
    if (!name) throw new Error("a referral with no client name read off it was not filed");
    const { data, error } = await admin.rpc("intake_referral", {
      p_doc: docId,
      p_name: name,
      p_counselor: read.fields.counselor?.value ?? "",
      p_office: read.fields.office?.value ?? "",
      p_date: read.fields.referralDate?.value ?? null,
      p_phone: read.fields.phone?.value ?? "",
    });
    if (error) throw new Error(error.message);
    filed = data as unknown as Filed;
  } else if (reading.kind === "Authorization") {
    const read = parseAuthorizationText(reading.text, { pages: 0, scanned });
    const { data, error } = await admin.rpc("intake_authorization", {
      p_doc: docId,
      p_number: read.fields.authNumber?.value ?? "",
      p_name: read.fields.clientName?.value ?? "",
      p_service: read.fields.serviceType?.value ?? "",
      p_start: read.fields.startDate?.value ?? null,
      p_end: read.fields.endDate?.value ?? null,
      p_from_scan: scanned,
    });
    if (error) throw new Error(error.message);
    filed = data as unknown as Filed;
  } else {
    // Rule 3: everything else. Filed against the client if the client is
    // clear, left in the queue if not, and nobody is told either way.
    const read = parseAuthorizationText(reading.text, { pages: 0, scanned });
    const { data, error } = await admin.rpc("intake_other", {
      p_doc: docId,
      p_name: read.fields.clientName?.value ?? "",
    });
    if (error) throw new Error(error.message);
    filed = data as unknown as Filed;
  }

  // Whether the counselor is thanked is the database's to say: one reply per
  // document, a re-send getting the same reply, so two overlapping polls
  // cannot both send it.
  const { data: reply } = await admin.rpc("intake_record_mail", {
    p_message: message.id,
    p_from: message.from,
    p_subject: message.subject,
    p_received: message.receivedAt,
    p_decision: filed.action,
    p_detail: filed.candidates ?? "",
    p_sha256: sha256,
    p_doc: docId,
    p_client: filed.client_id,
    p_reply: filed.reply,
  });

  return {
    reply: Boolean(reply),
    notify: filed.notify ?? [],
    summary: {
      decision: filed.action,
      kind: reading.kind,
      referral: Boolean(classification.referral),
      client_id: filed.client_id,
      notified: filed.notify?.length ?? 0,
    },
  };
}
