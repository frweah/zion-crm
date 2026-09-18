import "server-only";
import { ORG } from "@/lib/roles";

/**
 * Outgoing mail via Resend.
 *
 * Deliberately a plain fetch rather than the SDK: one endpoint, one shape, and
 * one less dependency to keep current in a system that will outlive this build.
 *
 * Returns a result rather than throwing, because the caller needs to tell the
 * difference between "the counselor has it" and "nothing was sent" — a form
 * must never be marked Sent when it was not.
 */
export type SendResult = { ok: true; id: string } | { ok: false; error: string };

export function emailConfigured(): boolean {
  return Boolean(process.env.RESEND_API_KEY);
}

const ADDRESS = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/**
 * Addresses typed into a CC box: split on commas, semicolons or spaces, the
 * To address and repeats removed. Returns the ones that do not look like an
 * address separately, so a typo is refused rather than silently dropped.
 */
export function parseCc(raw: string, to: string): { cc: string[]; bad: string[] } {
  const seen = new Set([to.trim().toLowerCase()]);
  const cc: string[] = [];
  const bad: string[] = [];
  for (const part of raw.split(/[,;\s]+/).map((p) => p.trim()).filter(Boolean)) {
    if (!ADDRESS.test(part)) {
      bad.push(part);
      continue;
    }
    if (seen.has(part.toLowerCase())) continue;
    seen.add(part.toLowerCase());
    cc.push(part);
  }
  return { cc, bad };
}

export async function sendEmail({
  to,
  cc,
  subject,
  text,
  replyTo,
}: {
  to: string;
  cc?: string[];
  subject: string;
  text: string;
  replyTo?: string;
}): Promise<SendResult> {
  const key = process.env.RESEND_API_KEY;
  if (!key) {
    return {
      ok: false,
      error:
        "Email is not set up yet. Add RESEND_API_KEY and verify zionvocrehab.com with Resend, then send again.",
    };
  }

  const from = process.env.EMAIL_FROM ?? `${ORG.name} <${ORG.email}>`;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [to],
        ...(cc && cc.length ? { cc } : {}),
        subject,
        text,
        ...(replyTo ? { reply_to: replyTo } : {}),
      }),
    });

    const body = (await res.json()) as { id?: string; message?: string; name?: string };

    if (!res.ok) {
      return { ok: false, error: body.message ?? `Resend returned ${res.status}.` };
    }
    if (!body.id) {
      return { ok: false, error: "Resend accepted the request but returned no message id." };
    }

    return { ok: true, id: body.id };
  } catch (err) {
    return {
      ok: false,
      error: `Could not reach the mail service: ${err instanceof Error ? err.message : "unknown error"}`,
    };
  }
}
