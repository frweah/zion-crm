import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import {
  ensureFreshToken,
  listEvents,
  listMessagesSince,
  addressesOf,
  clientNoFromSubject,
  type TokenBundle,
} from "@/lib/graph";

/**
 * One person's sync.
 *
 * The same code runs from the dashboard button and from the nightly cron. The
 * only difference is which pair of token functions the caller hands in — a
 * signed-in person can only ever reach their own, the cron reaches everybody's
 * through a function granted to the service role alone. Keeping that
 * difference in the caller means this file cannot read the wrong person's
 * mailbox even by mistake.
 */

export type SyncResult = {
  mailLogged: number;
  eventsPulled: number;
  skippedNoMatch: number;
  errors: string[];
};

export type TokenAccess = {
  read: () => Promise<TokenBundle | null>;
  write: (t: { accessToken: string; refreshToken: string | null; expiresAt: Date }) => Promise<void>;
};

export type MailRow = {
  clientId: string | null;
  counselorId: string | null;
  messageId: string;
  conversationId: string;
  subject: string;
  sentAt: string;
  direction: "Incoming" | "Outgoing";
  counterpart: string;
  webLink: string;
};

/**
 * How a mail record gets written.
 *
 * Insert on mail_log is revoked from the application role, so this is not a
 * table write — it is one of the two database functions that are allowed to
 * make one, and which one depends on whether there is a session. The caller
 * decides, for the same reason it decides which token functions to use.
 */
export type MailWriter = (row: MailRow) => Promise<{ logged: boolean; error?: string }>;

/** How far back a sweep looks when it has never run before. */
const FIRST_RUN_DAYS = 14;
/** How far either side of today the calendar pull looks. */
const CALENDAR_BACK_DAYS = 30;
const CALENDAR_FORWARD_DAYS = 60;

export async function syncStaffMember(
  supabase: SupabaseClient<Database>,
  staffId: string,
  tokens: TokenAccess,
  writeMail: MailWriter,
): Promise<SyncResult> {
  const result: SyncResult = { mailLogged: 0, eventsPulled: 0, skippedNoMatch: 0, errors: [] };

  const bundle = await tokens.read();
  if (!bundle) {
    result.errors.push("No Microsoft connection.");
    return result;
  }

  let token: string;
  try {
    token = await ensureFreshToken(bundle, tokens.write);
  } catch (err) {
    result.errors.push(err instanceof Error ? err.message : "Could not refresh the connection.");
    return result;
  }

  const { data: state } = await supabase
    .from("microsoft_sync_state")
    .select("last_mail_sync_at")
    .eq("staff_id", staffId)
    .maybeSingle();

  // ── who we know ────────────────────────────────────────────
  // Matching is by address, so the address book is loaded once rather than
  // queried per message. A practice this size has hundreds of rows, not
  // millions, and the alternative is a round trip for every email.
  const [{ data: clients }, { data: counselors }, { data: exclusions }] = await Promise.all([
    supabase.from("clients").select("id, client_no, email, name"),
    supabase.from("counselors").select("id, email, name"),
    supabase.from("mail_exclusions").select("conversation_id"),
  ]);

  const clientByEmail = new Map<string, string>();
  const clientByNo = new Map<number, string>();
  for (const c of clients ?? []) {
    if (c.email) clientByEmail.set(c.email.toLowerCase().trim(), c.id);
    if (c.client_no !== null) clientByNo.set(Number(c.client_no), c.id);
  }

  const counselorByEmail = new Map<string, string>();
  for (const c of counselors ?? []) {
    if (c.email) counselorByEmail.set(c.email.toLowerCase().trim(), c.id);
  }

  const excluded = new Set((exclusions ?? []).map((e) => e.conversation_id));

  // ── calendar: pull events tagged to a client ───────────────
  try {
    const from = new Date(Date.now() - CALENDAR_BACK_DAYS * 86400000);
    const to = new Date(Date.now() + CALENDAR_FORWARD_DAYS * 86400000);
    const events = await listEvents(token, from, to);

    for (const event of events) {
      if (event.isCancelled) continue;

      const clientNo = clientNoFromSubject(event.subject);
      if (clientNo === null) continue;

      const clientId = clientByNo.get(clientNo);
      // A tag naming a client that does not exist is a typo, not a client. It
      // is left alone rather than guessed at.
      if (!clientId) continue;

      const startsAt = event.start?.dateTime ? new Date(event.start.dateTime + "Z") : null;
      const endsAt = event.end?.dateTime ? new Date(event.end.dateTime + "Z") : null;
      if (!startsAt || !endsAt || endsAt <= startsAt) continue;

      // Upsert on (staff_id, outlook_event_id). An event already pushed from
      // the CRM matches its own row and is updated rather than duplicated,
      // which is the whole reason the pair is unique.
      const { error } = await supabase.from("calendar_events").upsert(
        {
          staff_id: staffId,
          client_id: clientId,
          outlook_event_id: event.id,
          outlook_web_link: event.webLink ?? "",
          title: (event.subject ?? "Appointment").trim(),
          starts_at: startsAt.toISOString(),
          ends_at: endsAt.toISOString(),
          location: event.location?.displayName ?? "",
          origin: "Outlook",
          push_state: "Not pushed",
        },
        { onConflict: "staff_id,outlook_event_id", ignoreDuplicates: false },
      );

      if (error) {
        result.errors.push(`Calendar: ${error.message}`);
      } else {
        result.eventsPulled += 1;
      }
    }
  } catch (err) {
    result.errors.push(err instanceof Error ? err.message : "Calendar sync failed.");
  }

  // ── mail: log what matches somebody we know ────────────────
  // Declared out here because the state write below needs them: the watermark
  // is how far this run actually got, and it is only honest if it survives the
  // block that computed it.
  let watermark: string | null = null;
  let truncated = false;

  try {
    const since = state?.last_mail_sync_at
      ? new Date(state.last_mail_sync_at)
      : new Date(Date.now() - FIRST_RUN_DAYS * 86400000);

    // The watermark advances only as far as the sweep actually looked. A run
    // that stops at the page cap leaves it on the last message it read, so the
    // next one carries on rather than skipping whatever was behind it.
    const page = await listMessagesSince(token, since);
    const messages = page.messages;
    truncated = page.truncated;

    for (const message of messages) {
      const conversationId = message.conversationId ?? "";
      if (conversationId && excluded.has(conversationId)) continue;

      const addresses = addressesOf(message);

      let clientId: string | null = null;
      let counselorId: string | null = null;
      let counterpart = "";

      for (const address of addresses) {
        const c = clientByEmail.get(address);
        if (c) {
          clientId = c;
          counterpart = address;
          break;
        }
        const k = counselorByEmail.get(address);
        if (k && !counselorId) {
          counselorId = k;
          counterpart = address;
        }
      }

      // No match, no record. This is the rule that keeps everything else in
      // the mailbox out of the CRM entirely: not stored and hidden, not
      // stored at all.
      if (!clientId && !counselorId) {
        // Looked at and deliberately not kept. The watermark still moves: not
        // storing a message is not a reason to read it again tomorrow.
        result.skippedNoMatch += 1;
        if (message.receivedDateTime) watermark = message.receivedDateTime;
        continue;
      }

      const fromAddress = message.from?.emailAddress?.address?.toLowerCase() ?? "";
      const direction = fromAddress === counterpart ? "Incoming" : "Outgoing";
      const sentAt = message.receivedDateTime ?? message.sentDateTime;
      if (!sentAt) continue;
      watermark = sentAt;

      const written = await writeMail({
        clientId,
        counselorId: clientId ? null : counselorId,
        messageId: message.id,
        conversationId,
        subject: (message.subject ?? "(no subject)").slice(0, 500),
        sentAt: new Date(sentAt).toISOString(),
        direction,
        counterpart,
        webLink: message.webLink ?? "",
      });

      if (written.error) {
        result.errors.push(`Mail: ${written.error}`);
      } else if (written.logged) {
        // Only a message that was actually new counts. Re-running a sweep
        // should report nothing new, not report the same mail again.
        result.mailLogged += 1;
      }
    }
  } catch (err) {
    result.errors.push(err instanceof Error ? err.message : "Mail sync failed.");
  }

  if (truncated) {
    result.errors.push(
      "There was more mail than one run reads. The rest will be picked up on the next sync.",
    );
  }

  const now = new Date().toISOString();
  await supabase.from("microsoft_sync_state").upsert(
    {
      staff_id: staffId,
      last_run_at: now,
      // Where the sweep got to, not the wall clock. Setting this to now after a
      // capped run would step over every message the run never read.
      last_mail_sync_at: watermark ?? now,
      last_calendar_sync_at: now,
      mail_logged: result.mailLogged,
      events_pulled: result.eventsPulled,
      last_error: result.errors.join("; ").slice(0, 500),
    },
    { onConflict: "staff_id" },
  );

  return result;
}

/**
 * One shared mailbox.
 *
 * Read with an Admin's own token under Mail.Read.Shared, so this reaches
 * exactly as far as Exchange has let that person reach and no further. The
 * matching rules are the same as for a personal mailbox, because they are the
 * point rather than an implementation detail: subject, date, direction and a
 * link, only where an address is already on a client or counselor record, and
 * nothing at all otherwise.
 */
export async function syncSharedMailbox(
  supabase: SupabaseClient<Database>,
  mailbox: { address: string; last_mail_sync_at: string | null },
  token: string,
  writeMail: (row: MailRow & { mailbox: string }) => Promise<{ logged: boolean; error?: string }>,
): Promise<SyncResult> {
  const result: SyncResult = { mailLogged: 0, eventsPulled: 0, skippedNoMatch: 0, errors: [] };

  const [{ data: clients }, { data: counselors }, { data: exclusions }] = await Promise.all([
    supabase.from("clients").select("id, email"),
    supabase.from("counselors").select("id, email"),
    supabase.from("mail_exclusions").select("conversation_id"),
  ]);

  const clientByEmail = new Map<string, string>();
  for (const c of clients ?? []) {
    if (c.email) clientByEmail.set(c.email.toLowerCase().trim(), c.id);
  }
  const counselorByEmail = new Map<string, string>();
  for (const c of counselors ?? []) {
    if (c.email) counselorByEmail.set(c.email.toLowerCase().trim(), c.id);
  }
  const excluded = new Set((exclusions ?? []).map((e) => e.conversation_id));

  const since = mailbox.last_mail_sync_at
    ? new Date(mailbox.last_mail_sync_at)
    : new Date(Date.now() - FIRST_RUN_DAYS * 86400000);

  let watermark: string | null = null;

  try {
    const page = await listMessagesSince(token, since, 5, mailbox.address);

    for (const message of page.messages) {
      const conversationId = message.conversationId ?? "";
      if (conversationId && excluded.has(conversationId)) continue;

      const addresses = addressesOf(message);
      let clientId: string | null = null;
      let counselorId: string | null = null;
      let counterpart = "";

      for (const address of addresses) {
        // The mailbox's own address is not a counterpart to itself.
        if (address === mailbox.address.toLowerCase()) continue;
        const c = clientByEmail.get(address);
        if (c) {
          clientId = c;
          counterpart = address;
          break;
        }
        const k = counselorByEmail.get(address);
        if (k && !counselorId) {
          counselorId = k;
          counterpart = address;
        }
      }

      if (!clientId && !counselorId) {
        result.skippedNoMatch += 1;
        if (message.receivedDateTime) watermark = message.receivedDateTime;
        continue;
      }

      const fromAddress = message.from?.emailAddress?.address?.toLowerCase() ?? "";
      const direction = fromAddress === counterpart ? "Incoming" : "Outgoing";
      const sentAt = message.receivedDateTime ?? message.sentDateTime;
      if (!sentAt) continue;
      watermark = sentAt;

      const written = await writeMail({
        mailbox: mailbox.address,
        clientId,
        counselorId: clientId ? null : counselorId,
        messageId: message.id,
        conversationId,
        subject: (message.subject ?? "(no subject)").slice(0, 500),
        sentAt: new Date(sentAt).toISOString(),
        direction,
        counterpart,
        webLink: message.webLink ?? "",
      });

      if (written.error) result.errors.push(`Mail: ${written.error}`);
      else if (written.logged) result.mailLogged += 1;
    }

    if (page.truncated) {
      result.errors.push(
        "There was more mail than one run reads. The rest will be picked up on the next sync.",
      );
    }
  } catch (err) {
    result.errors.push(err instanceof Error ? err.message : "Shared mailbox sync failed.");
  }

  await supabase
    .from("shared_mailboxes")
    .update({
      last_run_at: new Date().toISOString(),
      last_mail_sync_at: watermark ?? mailbox.last_mail_sync_at ?? new Date().toISOString(),
      mail_logged: result.mailLogged,
      last_error: result.errors.join("; ").slice(0, 500),
    })
    .eq("address", mailbox.address);

  return result;
}
