import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { carrierName, readSwitch, type Carrier, type Which } from "@/lib/carrier-switch";
import {
  findContactByPhone,
  upsertContact,
  sendSms as ghlSend,
  messageStatus as ghlStatus,
  smsConfigured as ghlConfigured,
} from "@/lib/ghl";
import {
  callbackUrl,
  sendSms as twilioSend,
  messageStatus as twilioStatus,
  textingNotReady as twilioNotReady,
} from "@/lib/twilio";

/**
 * Which carrier the practice is texting through, and the only code that asks.
 *
 * The one file in the application that knows there is more than one provider.
 * Above it, `lib/sms.ts` writes the record and asks the database's permission
 * and has no idea which company carries the message; below it, `lib/ghl.ts`
 * and `lib/twilio.ts` each know one company and nothing about the practice.
 * Cutover is a row in `org_settings`, and the reason it can be a row rather
 * than a deploy is that this is the only place that would have had to change.
 *
 * Nothing here writes to `sms_messages`, reads consent, or decides whether a
 * message may go. Those are the door's job (lib/sms.ts) and the database's,
 * and keeping them out of here is what stops a second provider becoming a
 * second set of rules.
 */

export { carrierName };
export type { Carrier, Which };

/**
 * Which carrier is live, asked of the database rather than the environment.
 *
 * A failed read is not an answer. The practice has been caught by that twice
 * — middleware that read an auth error as "revoked", `getCurrentStaff` that
 * read a failed query as "no access" and signed the whole practice out — and
 * the version of it here would be worse than either: falling back to a
 * default would send a client's text from whichever number happens not to be
 * the one the practice is using, and the reply would arrive somewhere nobody
 * is watching. So a switch that cannot be read refuses the send, and the
 * message is recorded as Failed with the reason, which leaves it retryable.
 */
export async function whichCarrier(supabase: SupabaseClient<Database>): Promise<Which> {
  return readSwitch(await supabase.rpc("sms_provider"));
}

/**
 * Whether the live carrier can send at all, in a sentence or not at all.
 *
 * Asked by the sweeps before they walk a list, so a missing key is one line
 * in a cron result rather than one failed message per client.
 */
export async function carrierNotReady(supabase: SupabaseClient<Database>): Promise<string | null> {
  const which = await whichCarrier(supabase);
  if (!which.ok) return which.error;
  if (which.carrier === "twilio") return twilioNotReady();
  return ghlConfigured()
    ? null
    : "Texting is not set up — GHL_API_KEY or GHL_LOCATION_ID is missing.";
}

export type Carried =
  | {
      ok: true;
      /** The provider's own id for the message, which is the practice's receipt. */
      providerId: string;
      carrier: Carrier;
      /**
       * A contact id worth caching on the client, where the carrier has such
       * a thing and this call had to create one. Twilio sends to a number and
       * has no contact to cache, so it is always null there — which is why
       * `clients.ghl_id` is left alone rather than repurposed.
       */
      learnedContactId: string | null;
    }
  | { ok: false; error: string; carrier: Carrier | null };

/**
 * Hand one text to whichever carrier is live.
 *
 * The two halves are deliberately not made to look alike beyond this
 * signature. GoHighLevel sends to a *contact*, so there is a lookup and
 * sometimes a create before anything goes; Twilio sends to a number through
 * the messaging service, which carries the sender, the opt-out handling and
 * the campaign registration. Flattening that difference into a shared shape
 * would mean inventing a contact on Twilio that nothing needs.
 */
export async function sendThroughCarrier(
  supabase: SupabaseClient<Database>,
  params: {
    to: string;
    body: string;
    /** The client's cached provider contact id, where there is one. */
    cachedContactId?: string | null;
    /** Whose number this is, for a carrier that insists on naming it. */
    recipientName: string;
  },
): Promise<Carried> {
  const which = await whichCarrier(supabase);
  if (!which.ok) return { ok: false, error: which.error, carrier: null };

  if (which.carrier === "twilio") {
    const sent = await twilioSend({
      to: params.to,
      body: params.body,
      statusCallback: callbackUrl("/api/twilio/status"),
    });
    if (!sent.ok) return { ok: false, error: sent.error, carrier: "twilio" };
    return { ok: true, providerId: sent.data.sid, carrier: "twilio", learnedContactId: null };
  }

  let contactId = params.cachedContactId ?? null;
  let learned: string | null = null;

  if (!contactId) {
    const found = await findContactByPhone(params.to);
    if (!found.ok) return { ok: false, error: found.error, carrier: "ghl" };
    contactId = found.data;
  }

  if (!contactId) {
    const made = await upsertContact({ phone: params.to, name: params.recipientName });
    if (!made.ok) return { ok: false, error: made.error, carrier: "ghl" };
    contactId = made.data;
    learned = made.data;
  }

  const sent = await ghlSend({ contactId, message: params.body });
  if (!sent.ok) return { ok: false, error: sent.error, carrier: "ghl" };
  return { ok: true, providerId: sent.data, carrier: "ghl", learnedContactId: learned };
}

/**
 * What the carrier now says about a message it took.
 *
 * Asked by the quarter-hourly catch-up. The receipt names the carrier by its
 * shape — Twilio's message ids begin SM or MM and GoHighLevel's do not — but
 * shape is not what is asked here: the row says which carrier carried it, and
 * the caller passes that, because a guess from a string is the kind of thing
 * that is right until the day it is not.
 */
export async function askCarrierStatus(
  supabase: SupabaseClient<Database>,
  params: { providerId: string; carriedBy: string | null },
): Promise<{ ok: true; status: string; error: string | null } | { ok: false; error: string }> {
  const carried = params.carriedBy ?? carrierName((await asCarrier(supabase)) ?? "ghl");

  const said =
    carried === "Twilio"
      ? await twilioStatus(params.providerId)
      : await ghlStatus(params.providerId);

  if (!said.ok) return { ok: false, error: said.error };
  return { ok: true, status: said.data.status, error: said.data.error };
}

/** The live carrier, or null where the switch could not be read. */
async function asCarrier(supabase: SupabaseClient<Database>): Promise<Carrier | null> {
  const which = await whichCarrier(supabase);
  return which.ok ? which.carrier : null;
}
