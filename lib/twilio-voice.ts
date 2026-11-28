import { createHmac } from "node:crypto";

/**
 * The two things a browser needs to be a telephone, as rules rather than
 * calls.
 *
 * No imports but node's own crypto and no environment read: the API key and
 * its secret are arguments. Same reason as lib/twilio-signature.ts - a token
 * nothing exercises is a token that either lets the wrong person answer the
 * client line or lets nobody answer it, and scripts/check-voice.mjs can only
 * run these over made-up input if they take their secrets as parameters.
 *
 * ── The token ──────────────────────────────────────────────
 *
 * Twilio's Voice SDK wants an access token, which is a JWT with one unusual
 * header: `cty: twilio-fpa;v=1`. It is signed with the API key *secret* and
 * issued by the API key *SID*, while the subject is the account. The identity
 * inside it is who the browser is, and every call answered on that browser
 * reports it - which is why the identity here is the staff id and nothing
 * friendlier. A call answered by "reception" is a call nobody can be asked
 * about afterwards.
 *
 * ── The greeting ───────────────────────────────────────────
 *
 * Exactly the owner's words, held in one place and asserted by the check,
 * because a greeting that drifts is one nobody notices has drifted.
 */

export const GREETING =
  "You've reached Zion Voc Rehab. We can't take your call right now. " +
  "Leave your name, number and a short message and we'll call you back, " +
  "or text this number for a quicker reply.";

/** How long a browser rings before the caller gets the greeting. */
export const RING_SECONDS = 25;

/** The longest message somebody can leave. */
export const VOICEMAIL_SECONDS = 120;

/** How often the browser says it is still there. Half the window it is trusted for. */
export const PRESENCE_REFRESH_MS = 60_000;

/**
 * The voice the line speaks in.
 *
 * Twilio's own `<Say>` voice reads the greeting the way a parking machine
 * reads a ticket number, and the greeting is the one sentence in this system
 * a member of the public hears. Amazon's neural Joanna reads it like a
 * person. Named once, because a line that answers in two voices sounds like
 * two practices.
 */
export const SAY_VOICE = "Polly.Joanna-Neural";

/**
 * How the practice's name is said, as against how it is written.
 *
 * Polly reads "Voc" as "voke". It is short for vocational, it rhymes with
 * rock, and the first thing a caller hears is the name of the practice being
 * got wrong. So the written form is left exactly as it is - every screen,
 * every report and every text still says "Zion Voc Rehab" - and only the
 * spoken one carries the pronunciation.
 *
 * `\u0251` is the vowel in "rock". <phoneme> is ordinary SSML rather than
 * one of the Amazon-specific tags Twilio's <Say> refuses, so a neural voice
 * takes it; if it turns out not to honour it, the whole fallback is this one
 * constant spelled "Vock" instead.
 */
const WRITTEN_NAME = "Zion Voc Rehab";
export const SPOKEN_NAME = `Zion <phoneme alphabet="ipa" ph="v\u0251k">Voc</phoneme> Rehab`;

/**
 * A second of quiet before the first word.
 *
 * A call's audio is still connecting when Twilio starts speaking, so without
 * this the caller hears "...reached Zion Voc Rehab" and the name of the
 * practice is the part that gets cut.
 */
export const LEAD_IN_SECONDS = 1;

const base64url = (input: Buffer | string): string =>
  Buffer.from(input).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export type VoiceGrant = {
  accountSid: string;
  apiKeySid: string;
  apiKeySecret: string;
  /** Who this browser is. The staff id, and nothing friendlier. */
  identity: string;
  /** The TwiML app that answers when this browser places a call. */
  applicationSid?: string | null;
  /** Seconds. Short on purpose: the browser asks again while it is open. */
  ttlSeconds?: number;
};

/**
 * A Voice access token for one member of staff.
 *
 * Incoming is allowed, which is the whole point - the practice line rings
 * here. Outgoing is granted only when there is a TwiML app to answer it, so a
 * deployment with no app SID can still take calls rather than failing to
 * issue a token at all.
 *
 * An hour, not a day. The browser refreshes it while the window is open, and
 * a token that outlives the session it was issued for is a token somebody
 * else can answer the client line with.
 */
export function voiceToken(grant: VoiceGrant): { token: string; expiresAt: number } {
  const now = Math.floor(Date.now() / 1000);
  const ttl = grant.ttlSeconds ?? 3600;
  const exp = now + ttl;

  const header = { cty: "twilio-fpa;v=1", typ: "JWT", alg: "HS256" };
  const payload = {
    jti: `${grant.apiKeySid}-${now}`,
    iss: grant.apiKeySid,
    sub: grant.accountSid,
    iat: now,
    nbf: now,
    exp,
    grants: {
      identity: grant.identity,
      voice: {
        incoming: { allow: true },
        ...(grant.applicationSid
          ? { outgoing: { application_sid: grant.applicationSid } }
          : {}),
      },
    },
  };

  const signing = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = base64url(
    createHmac("sha256", grant.apiKeySecret).update(signing).digest(),
  );
  return { token: `${signing}.${signature}`, expiresAt: exp * 1000 };
}

// ── TwiML ────────────────────────────────────────────────────

/**
 * XML, escaped.
 *
 * A client's name goes into the TwiML as a parameter, and a name with an
 * ampersand in it would otherwise produce a document Twilio refuses - which
 * is a caller hearing an error tone because somebody is called Fisher & Son.
 */
const xml = (s: string): string =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");

export function twimlDocument(body: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><Response>${body}</Response>`;
}

/**
 * Something said to whoever is on the line.
 *
 * The voice and the second of quiet are here rather than at each `<Say>`, so
 * there is one answer to what this practice sounds like and one place to
 * change it. The pause comes first on purpose: a pause after the words
 * quietens nothing and clips the first one anyway.
 */
/**
 * Words turned into what Polly is handed.
 *
 * Escaped first, so an apostrophe in the greeting or an ampersand in a
 * caller's name still cannot become markup, and only then is the one phrase
 * allowed to *be* markup put in. That order is the whole of it: substituting
 * first and escaping afterwards would escape the phoneme tag and read it out
 * loud, which is why this is not a plain xml() call.
 */
export const spokenWords = (words: string): string =>
  xml(words).split(xml(WRITTEN_NAME)).join(SPOKEN_NAME);

const say = (words: string): string =>
  `<Pause length="${LEAD_IN_SECONDS}"/><Say voice="${SAY_VOICE}">${spokenWords(words)}</Say>`;

/**
 * A call arriving: ring every desk that is there, then take a message.
 *
 * One `<Client>` per member of staff with a live token. Each one carries the
 * caller's name and the client it matched as parameters, because the browser
 * has no way to look either of them up and an incoming banner that says only
 * a phone number is a banner somebody has to go and search while it rings.
 *
 * `callerId` is the caller's own number, so a desk that has the number saved
 * shows what it has always shown.
 *
 * Nothing follows the `<Dial>` except the greeting and the recorder: no cell
 * phone fallback, by the owner's instruction. Twilio moves on to the next
 * verb by itself when nobody answers within the timeout, so the greeting is
 * what a caller gets when the office is empty - immediately when nobody is
 * signed in, because then there is no `<Dial>` at all.
 */
export function inboundTwiml(params: {
  callerId: string;
  /** Staff ids to ring. Empty means nobody is at a desk. */
  ring: string[];
  callerLabel: string;
  clientId: string | null;
  recordingStatusCallback: string | null;
}): string {
  const clients = params.ring
    .map(
      (id) =>
        `<Client><Identity>${xml(id)}</Identity>` +
        `<Parameter name="caller" value="${xml(params.callerLabel)}"/>` +
        `<Parameter name="clientId" value="${xml(params.clientId ?? "")}"/>` +
        `</Client>`,
    )
    .join("");

  const dial = clients
    ? `<Dial timeout="${RING_SECONDS}" callerId="${xml(params.callerId)}" answerOnBridge="true">${clients}</Dial>`
    : "";

  const record =
    say(GREETING) +
    `<Record maxLength="${VOICEMAIL_SECONDS}" playBeep="true" trim="trim-silence"` +
    (params.recordingStatusCallback
      ? ` recordingStatusCallback="${xml(params.recordingStatusCallback)}" recordingStatusCallbackMethod="POST"`
      : "") +
    `/>`;

  return twimlDocument(`${dial}${record}`);
}

/**
 * A member of staff placing a call from a client's record.
 *
 * The caller id is the practice line, always: a client seeing a Twilio number
 * they do not recognise is a client who does not answer, and a client seeing
 * the number they have always been rung from is the whole reason the practice
 * is keeping it.
 */
export function outboundTwiml(params: { to: string; callerId: string }): string {
  return twimlDocument(
    `<Dial callerId="${xml(params.callerId)}" answerOnBridge="true">` +
      `<Number>${xml(params.to)}</Number></Dial>`,
  );
}

/** What a caller hears when the practice cannot place their call. */
export function refusedTwiml(words: string): string {
  return twimlDocument(`${say(words)}<Hangup/>`);
}

/**
 * A number this practice is willing to dial.
 *
 * US and Canada, ten digits with the country code, and nothing else. It is
 * not a formatting nicety: the TwiML app's URL is the one place a signed-in
 * session could ask the practice's account to call anywhere in the world, and
 * an international premium-rate number is the way that gets expensive before
 * anybody notices.
 */
export function dialable(raw: string): string | null {
  const digits = (raw ?? "").replace(/[^0-9]/g, "");
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  if (digits.length === 10) return `+1${digits}`;
  return null;
}
