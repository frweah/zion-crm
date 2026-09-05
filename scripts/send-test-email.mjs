/**
 * Sends one test email to check the Resend setup.
 *
 *   node --env-file=.env.local scripts/send-test-email.mjs someone@example.com
 *
 * Uses the same request shape as lib/email.ts, so a pass here means the key,
 * the from address and the verified domain all work. It does not prove
 * deliverability to utah.gov — only a real send to a counselor does that.
 */
const to = process.argv[2];
if (!to) {
  console.error("Usage: node --env-file=.env.local scripts/send-test-email.mjs <email>");
  process.exit(1);
}

const key = process.env.RESEND_API_KEY;
const from = process.env.EMAIL_FROM;

if (!key) {
  console.error("RESEND_API_KEY is not set in .env.local");
  process.exit(1);
}
if (!from) {
  console.error("EMAIL_FROM is not set in .env.local");
  process.exit(1);
}

console.log(`from: ${from}`);
console.log(`to:   ${to}`);

const text = [
  "This is a test from the Zion Vocational Rehab CRM.",
  "",
  "If it arrived in the inbox and not in spam, outgoing mail is working and",
  "completed DWS-USOR forms can be emailed to counselors from the Forms tab.",
  "",
  "A real form arrives as plain text in this same shape:",
  "",
  "  STATE OF UTAH — DEPARTMENT OF WORKFORCE SERVICES — DWS-USOR 95",
  "  JOB COACHING TRACKER",
  "",
  "  Client Name: (client)   (Client #0000)",
  "  VR Counselor: (counselor)   Authorization #: (number)",
  "  CRP Company: Zion Vocational Rehabilitation Center   Vendor #: VC0000277370",
  "",
  "  ...the completed fields, then the electronic signature and date.",
  "",
  "Worth checking before the first real send: that this landed in the inbox,",
  "that the sender shows as service@zionvocrehab.com, and that replying to it",
  "reaches someone who reads it.",
].join("\n");

const res = await fetch("https://api.resend.com/emails", {
  method: "POST",
  headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
  body: JSON.stringify({
    from,
    to: [to],
    subject: "Zion CRM — outgoing mail test",
    text,
  }),
});

const body = await res.json();

if (!res.ok) {
  console.error(`\nFAILED (${res.status}): ${body.message ?? JSON.stringify(body)}`);
  process.exit(2);
}

console.log(`\nAccepted by Resend. Message id: ${body.id}`);
console.log("Check the inbox — and the spam folder, which is the answer that matters.");
