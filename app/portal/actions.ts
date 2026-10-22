"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { requestContext, requirePortal } from "@/lib/portal/session";
import { deliverCode } from "@/lib/portal/deliver";

export type PortalFormState = {
  error: string | null;
  ok?: string | null;
  /** The code is spent: the only way on is a new one. */
  restart?: boolean;
  /** What was typed, so a mistake does not mean typing it all again. */
  value?: string;
};

const ATTEMPT = "zion_portal_attempt";
const VIA = "zion_portal_via";
const HELP = "call Zion at 385-406-3432";

// The attempt id, not the phone number or email: nothing personal in a cookie.
function attemptCookie(maxAge: number) {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax" as const,
    path: "/portal",
    maxAge,
  };
}

// ── asking for a code ──────────────────────────────────────
export async function requestCode(_prev: PortalFormState, formData: FormData): Promise<PortalFormState> {
  const identifier = String(formData.get("identifier") ?? "").trim();
  const isEmail = identifier.includes("@");
  const digits = identifier.replace(/\D/g, "");

  if (!identifier) return { error: "Enter your mobile number or your email address.", value: identifier };
  if (isEmail && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(identifier)) {
    return { error: "That email address looks incomplete. Check it and try again.", value: identifier };
  }
  if (!isEmail && !(digits.length === 10 || (digits.length === 11 && digits.startsWith("1")))) {
    return { error: "Enter a 10-digit mobile number, like 801-555-0123.", value: identifier };
  }

  const { ip } = await requestContext();
  const admin = createAdminClient();
  const { data, error } = await admin.rpc("portal_issue_code", { p_identifier: identifier, p_ip: ip });
  const row = ((data ?? []) as {
    attempt_id: string;
    account_id: string | null;
    channel: "Text" | "Email";
    destination: string | null;
    account_name: string | null;
    code: string | null;
  }[])[0];

  if (error || !row) {
    console.error(`[portal] a code could not be issued: ${error?.message ?? "no row"}`);
    return { error: `A code could not be sent just now. Wait a minute and try again, or ${HELP}.`, value: identifier };
  }

  // Only when somebody has access there, and no code went out in the last
  // minute. Otherwise the page that follows reads exactly the same.
  if (row.code && row.destination) {
    const sent = await deliverCode({
      channel: row.channel,
      destination: row.destination,
      name: row.account_name ?? "",
      code: row.code,
    });
    await admin
      .from("portal_login_codes")
      .update({ sent: sent.ok, send_error: sent.ok ? "" : sent.error.slice(0, 300) })
      .eq("id", row.attempt_id);
    if (!sent.ok) console.error(`[portal] a sign-in code was not delivered by ${row.channel}: ${sent.error}`);
  }

  const jar = await cookies();
  jar.set(ATTEMPT, row.attempt_id, attemptCookie(600));
  jar.set(VIA, isEmail ? "email" : "text", attemptCookie(600));
  redirect("/portal/verify");
}

// ── entering it ────────────────────────────────────────────
export async function verifyCode(_prev: PortalFormState, formData: FormData): Promise<PortalFormState> {
  const code = String(formData.get("code") ?? "").replace(/\D/g, "");
  if (code.length !== 6) return { error: "Enter the 6 numbers from your code." };

  const jar = await cookies();
  const attempt = jar.get(ATTEMPT)?.value;
  if (!attempt) redirect("/portal/sign-in?ended=code");

  const { ip, userAgent } = await requestContext();
  const admin = createAdminClient();
  const { data, error } = await admin.rpc("portal_check_code", { p_attempt: attempt, p_code: code, p_ip: ip });
  const row = ((data ?? []) as { result: string; account_id: string | null; sign_in_email: string | null }[])[0];

  if (error || !row) {
    console.error(`[portal] a code could not be checked: ${error?.message ?? "no row"}`);
    return { error: `Your code could not be checked just now. Try again, or ${HELP}.` };
  }
  if (row.result === "wrong") {
    return { error: "That code does not match. Check the 6 numbers and try again." };
  }
  if (row.result !== "ok" || !row.account_id || !row.sign_in_email) {
    jar.set(ATTEMPT, "", attemptCookie(0));
    return {
      error:
        row.result === "locked"
          ? "That code was entered wrong too many times, so it no longer works. Ask for a new code."
          : "That code has expired. Codes work for 10 minutes. Ask for a new code.",
      restart: true,
    };
  }

  const cannot = (why: string): PortalFormState => {
    console.error(`[portal] sign-in could not be completed: ${why}`);
    return { error: `You could not be signed in just now. Ask for a new code, or ${HELP}.`, restart: true };
  };

  // The first time: the sign-in user. The database creates it only for this
  // account, and links the two (link_staff_account, 0087).
  const { data: account } = await admin
    .from("portal_accounts")
    .select("auth_user_id")
    .eq("id", row.account_id)
    .maybeSingle();
  if (!account) return cannot("the account was not found");
  if (!account.auth_user_id) {
    const { error: createError } = await admin.auth.admin.createUser({
      email: row.sign_in_email,
      email_confirm: true,
      user_metadata: { portal: true },
    });
    if (createError) return cannot(createError.message);
  }

  // A session, made on the server: a one-use link token, redeemed at once, so
  // no link is ever sent anywhere.
  const { data: link, error: linkError } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email: row.sign_in_email,
  });
  if (linkError || !link?.properties?.hashed_token) return cannot(linkError?.message ?? "no link token");

  const supabase = await createClient();
  const { error: otpError } = await supabase.auth.verifyOtp({
    type: "magiclink",
    token_hash: link.properties.hashed_token,
  });
  if (otpError) return cannot(otpError.message);

  const { error: beginError } = await supabase.rpc("portal_begin_session", { p_ip: ip, p_user_agent: userAgent });
  if (beginError) {
    await supabase.auth.signOut({ scope: "local" });
    return cannot(beginError.message);
  }

  jar.set(ATTEMPT, "", attemptCookie(0));
  jar.set(VIA, "", attemptCookie(0));
  redirect("/portal");
}

// ── consent ────────────────────────────────────────────────
export async function giveConsent(_prev: PortalFormState, formData: FormData): Promise<PortalFormState> {
  const me = await requirePortal({ consented: false });
  const { ip, userAgent } = await requestContext();
  const supabase = await createClient();

  const { error } = await supabase.rpc("portal_record_consent", {
    p_kind: "Electronic communication",
    p_given: true,
    p_ip: ip,
    p_user_agent: userAgent,
  });
  if (error) return { error: error.message };

  // Unticked means nothing is recorded about texts: leaving an optional box
  // empty is not the same as asking Zion to stop texting.
  if (formData.get("texts") === "yes" && !me.texts) {
    const { error: textError } = await supabase.rpc("portal_record_consent", {
      p_kind: "Text messages",
      p_given: true,
      p_ip: ip,
      p_user_agent: userAgent,
    });
    if (textError) redirect("/portal/settings?texts=not-saved");
  }
  redirect("/portal");
}

export async function setTexts(_prev: PortalFormState, formData: FormData): Promise<PortalFormState> {
  await requirePortal();
  const given = formData.get("texts") === "on";
  const { ip, userAgent } = await requestContext();
  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_record_consent", {
    p_kind: "Text messages",
    p_given: given,
    p_ip: ip,
    p_user_agent: userAgent,
  });
  if (error) return { error: error.message };
  redirect(`/portal/settings?texts=${given ? "on" : "off"}`);
}

export async function withdrawConsent(): Promise<PortalFormState> {
  await requirePortal();
  const { ip, userAgent } = await requestContext();
  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_record_consent", {
    p_kind: "Electronic communication",
    p_given: false,
    p_ip: ip,
    p_user_agent: userAgent,
  });
  if (error) return { error: error.message };
  redirect("/portal/consent?withdrawn=1");
}

/** "Stay signed in", from the idle warning. */
export async function keepAlive(): Promise<boolean> {
  await requirePortal({ consented: false });
  return true;
}

// ── messages (portal brief, section 2) ─────────────────────
export async function sendPortalMessage(_prev: PortalFormState, formData: FormData): Promise<PortalFormState> {
  await requirePortal();
  const body = String(formData.get("body") ?? "");
  if (!body.trim()) return { error: "Write your message first.", value: body };
  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_send_message", { p_body: body });
  if (error) return { error: error.message, value: body };
  revalidatePath("/portal/messages");
  return { error: null, ok: "Sent. Zion will answer here, and we will let you know when we do." };
}

export async function markPortalRead(seq: number): Promise<void> {
  await requirePortal();
  const supabase = await createClient();
  await supabase.rpc("portal_mark_read", { p_seq: seq });
}

/** How the client is told something is waiting: their choice, text or email. */
export async function setNoticeChannel(_prev: PortalFormState, formData: FormData): Promise<PortalFormState> {
  await requirePortal();
  const channel = String(formData.get("channel") ?? "");
  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_set_notice_channel", { p_channel: channel });
  if (error) return { error: error.message };
  revalidatePath("/portal/settings");
  return { error: null, ok: channel === "Text" ? "We will tell you by text." : "We will tell you by email." };
}

// ── documents Zion asked for (portal brief, section 3) ─────
const UPLOAD_MAX_BYTES = 50 * 1024 * 1024; // the bucket's own limit, as for staff
const UPLOAD_TYPES = new Set([
  "application/pdf",
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/webp",
  "image/tiff",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "text/plain",
  "text/csv",
]);

export type UploadTarget = { error: string | null; path?: string; token?: string };

/**
 * A one-time address to upload one file for one request.
 *
 * The database decides whether this client may answer this request and
 * names the exact place (portal_upload_path, 0228); only then is an upload
 * address minted, for that place and nothing else. The bytes then go from
 * the phone straight to storage - not through this server, which could not
 * carry a 50 MB photo anyway.
 */
export async function startUpload(params: {
  requestId: string;
  filename: string;
  size: number;
  type: string;
}): Promise<UploadTarget> {
  await requirePortal();
  if (params.size <= 0) return { error: "That file is empty. Choose another one." };
  if (params.size > UPLOAD_MAX_BYTES) {
    return { error: "That file is over 50 MB. Take the photo again at a smaller size, or call 385-406-3432." };
  }
  if (!UPLOAD_TYPES.has(params.type)) {
    return { error: "That kind of file cannot be uploaded. Send a photo, a PDF or a Word document." };
  }
  const supabase = await createClient();
  const { data: path, error } = await supabase.rpc("portal_upload_path", {
    p_request: params.requestId,
    p_filename: params.filename,
  });
  if (error || !path) return { error: error?.message ?? "The upload could not start. Try again." };

  const { data, error: signError } = await createAdminClient().storage.from("client-files").createSignedUploadUrl(path);
  if (signError || !data) {
    console.error(`[portal] no upload address: ${signError?.message ?? "none"}`);
    return { error: `The upload could not start. Try again in a minute, or ${HELP}.` };
  }
  return { error: null, path, token: data.token };
}

export async function finishUpload(params: {
  requestId: string;
  path: string;
  filename: string;
  type: string;
  size: number;
  sha256: string;
}): Promise<PortalFormState> {
  await requirePortal();
  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_answer_request", {
    p_request: params.requestId,
    p_path: params.path,
    p_filename: params.filename,
    p_mime: params.type,
    p_size: params.size,
    p_sha256: params.sha256,
  });
  if (error) {
    // The bytes are in storage but filed nowhere. Only a path this request
    // was handed out is removed - anything else was never ours to touch.
    if (params.path.startsWith("portal/") && params.path.includes(`/${params.requestId}/`)) {
      await createAdminClient().storage.from("client-files").remove([params.path]);
    }
    return { error: error.message };
  }
  revalidatePath("/portal/documents");
  revalidatePath("/portal");
  return { error: null, ok: "Uploaded. Zion will look at it and let you know if anything is missing." };
}
