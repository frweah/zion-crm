import "server-only";
import { timingSafeEqual } from "node:crypto";
import { expectedSignature, signedUrl } from "@/lib/twilio-signature";

/**
 * Twilio, as much of it as a client line needs.
 *
 * A plain fetch against the REST API rather than the SDK, for the reason
 * lib/ghl.ts and lib/email.ts give: two endpoints, one shape, and one less
 * dependency to keep current in a system that will outlive this build. The
 * SDK would also pull a request stack of its own into a serverless function
 * whose whole job is one POST.
 *
 * Every function returns a result rather than throwing, because the caller
 * has to tell the difference between "the client has it" and "nothing was
 * sent". A message recorded as sent when it was not is worse than an error.
 *
 * Two credentials, doing two different jobs, and they are not
 * interchangeable:
 *
 *   - The **API key pair** signs outbound REST calls. It is scoped and can be
 *     destroyed without touching the account, which is why it is preferred
 *     over the account's own auth token for sending.
 *   - The **auth token** is what Twilio signs its webhooks with. There is no
 *     choice about that one: a request arriving here can only be proved to be
 *     Twilio's by recomputing the signature with the account's auth token.
 *
 * Nothing in this file reads whether Twilio is the live carrier. That is
 * lib/text-provider.ts's one job, and the two are kept apart so that the
 * question "who are we sending through" has exactly one answer in exactly one
 * place.
 */

const BASE = "https://api.twilio.com/2010-04-01";

export type TwilioResult<T> = { ok: true; data: T } | { ok: false; error: string };

/**
 * Everything needed to send one text.
 *
 * The messaging service carries the number, the opt-out handling and the
 * campaign registration, so the practice sends *through the service* rather
 * than from a number: a number swapped inside the service needs no deploy
 * here, which is the whole reason A2A traffic is registered that way.
 */
export function textingConfigured(): boolean {
  return Boolean(
    process.env.TWILIO_ACCOUNT_SID &&
      process.env.TWILIO_API_KEY_SID &&
      process.env.TWILIO_API_KEY_SECRET &&
      process.env.TWILIO_MESSAGING_SERVICE_SID,
  );
}

/** What is missing, named, so a screen can say which one. */
export function textingNotReady(): string | null {
  const missing = (
    [
      ["TWILIO_ACCOUNT_SID", process.env.TWILIO_ACCOUNT_SID],
      ["TWILIO_API_KEY_SID", process.env.TWILIO_API_KEY_SID],
      ["TWILIO_API_KEY_SECRET", process.env.TWILIO_API_KEY_SECRET],
      ["TWILIO_MESSAGING_SERVICE_SID", process.env.TWILIO_MESSAGING_SERVICE_SID],
    ] as const
  )
    .filter(([, value]) => !value)
    .map(([name]) => name);
  return missing.length === 0 ? null : `Twilio is not set up yet — ${missing.join(", ")} is missing.`;
}

/** Whether a webhook can be proved to be Twilio's at all. */
export function signingConfigured(): boolean {
  return Boolean(process.env.TWILIO_AUTH_TOKEN);
}

/**
 * How long to wait for Twilio before giving up on a call.
 *
 * Named once, here, because the timeout and the sentence a person reads when
 * it fires have to agree about the number — and because of what happened
 * without one on the other provider: fifteen outgoing texts sat at 'Queued'
 * for five days because the function was killed at its own limit before the
 * code that would have marked them Failed ever ran (0286).
 */
const TWILIO_TIMEOUT_MS = 20_000;

function authorization(): string {
  const pair = `${process.env.TWILIO_API_KEY_SID}:${process.env.TWILIO_API_KEY_SECRET}`;
  return `Basic ${Buffer.from(pair).toString("base64")}`;
}

async function call<T>(path: string, form: Record<string, string>): Promise<TwilioResult<T>> {
  const notReady = textingNotReady();
  if (notReady) return { ok: false, error: notReady };

  try {
    const res = await fetch(`${BASE}/Accounts/${process.env.TWILIO_ACCOUNT_SID}${path}`, {
      method: "POST",
      headers: {
        Authorization: authorization(),
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
      },
      body: new URLSearchParams(form).toString(),
      cache: "no-store",
      signal: AbortSignal.timeout(TWILIO_TIMEOUT_MS),
    });

    const text = await res.text();
    let body: unknown = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = null;
    }

    if (!res.ok) {
      /**
       * Twilio's own sentence, and its code, which is the half that is
       * searchable.
       *
       * 21610 is a number the practice will meet: the person has texted STOP,
       * and the messaging service refuses on their behalf whatever our own
       * table says. That refusal is recorded on the message like any other,
       * so the row says why rather than saying nothing.
       */
      const said = body as { message?: string; code?: number; more_info?: string } | null;
      const words = said?.message ?? text.slice(0, 200) ?? `HTTP ${res.status}`;
      return { ok: false, error: said?.code ? `${said.code} ${words}` : `${res.status} ${words}` };
    }

    return { ok: true, data: body as T };
  } catch (err) {
    // A timeout reads as "TimeoutError: The operation was aborted due to
    // timeout", which tells a person nothing about what to do. The practice's
    // own sentence instead, naming the thing that did not answer.
    if (err instanceof Error && (err.name === "TimeoutError" || err.name === "AbortError")) {
      return {
        ok: false,
        error: `Twilio did not answer within ${TWILIO_TIMEOUT_MS / 1000} seconds.`,
      };
    }
    return {
      ok: false,
      error: err instanceof Error ? err.message : "The request could not be made.",
    };
  }
}

/**
 * Send one text. Returns the message SID, which is our receipt.
 *
 * Through the messaging service, never from a bare number, and with a status
 * callback: Twilio answering "queued" is not the carrier answering
 * "delivered", and the practice learned on the other provider what it costs
 * to treat the two as the same thing (0287).
 */
export async function sendSms(params: {
  to: string;
  body: string;
  statusCallback?: string | null;
}): Promise<TwilioResult<{ sid: string; status: string }>> {
  const form: Record<string, string> = {
    MessagingServiceSid: process.env.TWILIO_MESSAGING_SERVICE_SID!,
    To: params.to,
    Body: params.body,
  };
  if (params.statusCallback) form.StatusCallback = params.statusCallback;

  const result = await call<{ sid?: string; status?: string }>("/Messages.json", form);
  if (!result.ok) return result;

  const sid = result.data?.sid;
  if (!sid) {
    return { ok: false, error: "Twilio accepted the message and returned no id for it." };
  }
  return { ok: true, data: { sid, status: result.data?.status ?? "queued" } };
}

/**
 * What Twilio now says about a message it took.
 *
 * The other way round from the status callback: the practice asks, rather
 * than waiting to be told. Both exist because a callback is one HTTP request
 * and one HTTP request can be lost — a function cold-starting past its
 * timeout, a deploy swapping underneath it — and a text whose only record of
 * delivery was that lost request would read as 'Sent' for ever. Asking needs
 * nothing but the receipt the practice already holds.
 */
export async function messageStatus(
  sid: string,
): Promise<TwilioResult<{ status: string; error: string | null }>> {
  const notReady = textingNotReady();
  if (notReady) return { ok: false, error: notReady };

  try {
    const res = await fetch(
      `${BASE}/Accounts/${process.env.TWILIO_ACCOUNT_SID}/Messages/${encodeURIComponent(sid)}.json`,
      {
        headers: { Authorization: authorization(), Accept: "application/json" },
        cache: "no-store",
        signal: AbortSignal.timeout(TWILIO_TIMEOUT_MS),
      },
    );
    const text = await res.text();
    let body: unknown = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = null;
    }

    if (!res.ok) {
      const said = body as { message?: string; code?: number } | null;
      const words = said?.message ?? text.slice(0, 200) ?? `HTTP ${res.status}`;
      return { ok: false, error: said?.code ? `${said.code} ${words}` : `${res.status} ${words}` };
    }

    const said = body as { status?: string; error_message?: string | null } | null;
    if (!said?.status) {
      return { ok: false, error: "Twilio answered about that message without saying its status." };
    }
    return { ok: true, data: { status: said.status, error: said.error_message ?? null } };
  } catch (err) {
    if (err instanceof Error && (err.name === "TimeoutError" || err.name === "AbortError")) {
      return {
        ok: false,
        error: `Twilio did not answer within ${TWILIO_TIMEOUT_MS / 1000} seconds.`,
      };
    }
    return {
      ok: false,
      error: err instanceof Error ? err.message : "The request could not be made.",
    };
  }
}

/**
 * Where Twilio should post back to.
 *
 * Built from the site's own address rather than guessed from the request,
 * because the message that needs the callback is often sent from a sweep that
 * has no request. An unset address means no callback is asked for: the
 * quarter-hourly catch-up then settles the status instead, which is slower
 * and still true, where a callback pointed at the wrong host would be a
 * status nobody ever receives.
 */
export function callbackUrl(path: string): string | null {
  const base = (process.env.NEXT_PUBLIC_SITE_URL ?? "").replace(/\/$/, "");
  if (!base) return null;
  return `${base}${path}`;
}

// ── proving a webhook is Twilio's ────────────────────────────

/**
 * The two halves of proving a webhook are in lib/twilio-signature.ts.
 *
 * They are there rather than here because they are a rule and not a call: no
 * imports, no environment, the auth token passed in. That is what lets
 * scripts/check-twilio.mjs run the scheme over Twilio's own published example
 * and over requests built to fail, which is the only way to know a signature
 * check does anything.
 */

export type Proof =
  | { ok: true; params: Record<string, string> }
  | { ok: false; status: number; error: string };

/**
 * Read a Twilio webhook, or refuse it.
 *
 * The body is consumed here and handed back as plain parameters, because it
 * can only be read once and the signature needs all of it. Nothing downstream
 * sees an unproven request.
 *
 * An unset auth token answers 500 rather than waving the request through. A
 * webhook that cannot check its signature is not a webhook that has decided
 * the request is fine — the practice has made that mistake in the other
 * direction before, where a check that could not get an answer read it as
 * "no", and this is the same rule from the other side.
 */
export async function readSignedWebhook(request: Request): Promise<Proof> {
  if (!signingConfigured()) {
    return { ok: false, status: 500, error: "TWILIO_AUTH_TOKEN is not set" };
  }

  const presented = request.headers.get("x-twilio-signature") ?? "";
  if (!presented) {
    return { ok: false, status: 401, error: "Unsigned" };
  }

  let params: Record<string, string>;
  try {
    const form = await request.formData();
    params = {};
    for (const [key, value] of form.entries()) {
      if (typeof value === "string") params[key] = value;
    }
  } catch {
    return { ok: false, status: 400, error: "Expected a form-encoded body." };
  }

  const expected = expectedSignature(
    process.env.TWILIO_AUTH_TOKEN!,
    signedUrl(request.url, request.headers),
    params,
  );
  const a = Buffer.from(presented);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    return { ok: false, status: 401, error: "Unauthorized" };
  }

  return { ok: true, params };
}
