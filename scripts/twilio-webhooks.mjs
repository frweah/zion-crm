/**
 * Point a Twilio number and the TwiML app at a deployment of this CRM.
 *
 *   node --env-file=.env.local scripts/twilio-webhooks.mjs --dry
 *   node --env-file=.env.local scripts/twilio-webhooks.mjs --base https://crm.zionvocrehab.com
 *
 * The owner runs this, because the owner holds the keys. It reads
 * TWILIO_ACCOUNT_SID, TWILIO_API_KEY_SID and TWILIO_API_KEY_SECRET from the
 * environment, uses them, and never prints them or writes them anywhere -
 * which is also why this is a script rather than something done by hand in
 * the console: the four URLs have to agree with the four routes character for
 * character, and a trailing slash typed into a web form is a signature that
 * never validates and a webhook that refuses every message.
 *
 *   --base <url>     the deployment to point at. Defaults to
 *                    NEXT_PUBLIC_SITE_URL.
 *   --number <e164>  which number. Defaults to TWILIO_FROM_NUMBER.
 *   --dry            say what would change, change nothing.
 *   --voice-only     leave the messaging URLs alone (for pointing voice at a
 *                    preview while texting stays on the live site).
 *
 * It prints the before and after for each URL, so "restore both to
 * crm.zionvocrehab.com" is a step somebody can check rather than remember.
 */

const args = process.argv.slice(2);
const flag = (name) => args.includes(`--${name}`);
const value = (name) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
};

const base = (value("base") ?? process.env.NEXT_PUBLIC_SITE_URL ?? "").replace(/\/$/, "");
const number = value("number") ?? process.env.TWILIO_FROM_NUMBER ?? "";
const dry = flag("dry");
const voiceOnly = flag("voice-only");

const account = process.env.TWILIO_ACCOUNT_SID;
const keySid = process.env.TWILIO_API_KEY_SID;
const keySecret = process.env.TWILIO_API_KEY_SECRET;
const appSid = process.env.TWILIO_TWIML_APP_SID;

const missing = Object.entries({
  TWILIO_ACCOUNT_SID: account,
  TWILIO_API_KEY_SID: keySid,
  TWILIO_API_KEY_SECRET: keySecret,
})
  .filter(([, v]) => !v)
  .map(([k]) => k);

if (missing.length > 0) {
  console.error(`  ${missing.join(", ")} is not set, so nothing can be asked of Twilio.`);
  process.exit(1);
}
if (!base.startsWith("https://")) {
  console.error("  --base has to be an https address: Twilio signs the URL it was given.");
  process.exit(1);
}
if (!number) {
  console.error("  --number, or TWILIO_FROM_NUMBER, has to say which number to point.");
  process.exit(1);
}

const auth = `Basic ${Buffer.from(`${keySid}:${keySecret}`).toString("base64")}`;
const API = `https://api.twilio.com/2010-04-01/Accounts/${account}`;

async function twilio(path, form) {
  const res = await fetch(`${API}${path}`, {
    method: form ? "POST" : "GET",
    headers: {
      Authorization: auth,
      Accept: "application/json",
      ...(form ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
    },
    body: form ? new URLSearchParams(form).toString() : undefined,
  });
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  if (!res.ok) {
    // Twilio's own words and code. Never the request body: it carries the URLs
    // and, on a POST, nothing secret - but the header does, and a dump of the
    // request is how a key ends up in a terminal somebody screenshots.
    const said = body?.message ?? text.slice(0, 200);
    throw new Error(`${body?.code ?? res.status} ${said}`);
  }
  return body;
}

/** What each thing should point at. */
const want = {
  voiceUrl: `${base}/api/twilio/voice`,
  voiceStatus: `${base}/api/twilio/call-status`,
  smsUrl: `${base}/api/twilio/sms`,
  outboundVoiceUrl: `${base}/api/twilio/voice-out`,
};

const found = await twilio(`/IncomingPhoneNumbers.json?PhoneNumber=${encodeURIComponent(number)}`);
const row = found?.incoming_phone_numbers?.[0];
if (!row) {
  console.error(`  ${number} is not a number on this account, so there is nothing to point.`);
  process.exit(1);
}

console.log(`  ${number} (${row.friendly_name ?? "no name"})`);
const changes = [
  ["voice", row.voice_url, want.voiceUrl, "VoiceUrl"],
  ["voice status", row.status_callback, want.voiceStatus, "StatusCallback"],
  ...(voiceOnly ? [] : [["sms", row.sms_url, want.smsUrl, "SmsUrl"]]),
];

for (const [say, before, after] of changes) {
  console.log(`    ${say}: ${before || "(nothing)"}`);
  console.log(`         -> ${after}${before === after ? "  (already)" : ""}`);
}

if (!dry) {
  const form = {
    VoiceUrl: want.voiceUrl,
    VoiceMethod: "POST",
    StatusCallback: want.voiceStatus,
    StatusCallbackMethod: "POST",
  };
  if (!voiceOnly) {
    form.SmsUrl = want.smsUrl;
    form.SmsMethod = "POST";
  }
  await twilio(`/IncomingPhoneNumbers/${row.sid}.json`, form);
  console.log("    set");
}

if (appSid) {
  const app = await twilio(`/Applications/${appSid}.json`);
  console.log(`  TwiML app (${app?.friendly_name ?? "no name"})`);
  console.log(`    voice: ${app?.voice_url || "(nothing)"}`);
  console.log(
    `         -> ${want.outboundVoiceUrl}${app?.voice_url === want.outboundVoiceUrl ? "  (already)" : ""}`,
  );
  if (!dry) {
    await twilio(`/Applications/${appSid}.json`, {
      VoiceUrl: want.outboundVoiceUrl,
      VoiceMethod: "POST",
    });
    console.log("    set");
  }
} else {
  console.log("  TWILIO_TWIML_APP_SID is not set, so click-to-call has nothing to point.");
}

console.log("");
console.log(
  dry
    ? "  nothing was changed. Run it again without --dry to set them."
    : "  done. Putting these back on crm.zionvocrehab.com is a step on the cutover list.",
);
