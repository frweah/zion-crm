import "server-only";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

/**
 * Who is signed in to the client portal.
 *
 * To Supabase a portal client is an ordinary signed-in user. What makes them a
 * portal client - and nothing more - lives in the database (0087): an account
 * linked to the user, and a session for this sign-in that has not ended and
 * was used in the last 30 minutes. This file asks the database those questions
 * and sends the person where the answer says. The rules themselves are RLS;
 * someone who got past a redirect here would still read nothing.
 */

export const IDLE_MINUTES = 30;

/** The sign-in address each portal account is given. Nobody receives mail there. */
export function isPortalLogin(email: string | null | undefined): boolean {
  return /^p-[0-9a-f-]{36}@portal\.zionvocrehab\.com$/i.test(email ?? "");
}

export type PortalMe = {
  account_id: string;
  kind: "Client" | "Guardian";
  name: string;
  relationship: string;
  client_first_name: string;
  staff_first_name: string | null;
  terms_version: string | null;
  electronic: boolean;
  texts: boolean;
  phone_last4: string | null;
};

/** What consent is recorded with: the address and browser the request came from. */
export async function requestContext(): Promise<{ ip: string; userAgent: string }> {
  const h = await headers();
  const forwarded = (h.get("x-forwarded-for") ?? "").split(",")[0].trim();
  return { ip: forwarded || h.get("x-real-ip") || "", userAgent: h.get("user-agent") ?? "" };
}

/**
 * Use in every portal page and action past sign-in. Keeps the session alive,
 * or ends it if it has been idle 30 minutes; and, unless told otherwise, sends
 * anyone who has not agreed to the current terms to the consent screen.
 */
export async function requirePortal(options: { consented?: boolean } = {}): Promise<PortalMe> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/portal/sign-in");
  // A member of staff who opens the portal is not a client of it.
  if (!isPortalLogin(user.email)) redirect("/dashboard");

  const { data: state } = await supabase.rpc("portal_touch_session");
  if (state !== "ok") redirect(`/portal/sign-in?ended=${state === "expired" ? "idle" : "ended"}`);

  const { data } = await supabase.rpc("portal_me");
  const me = ((data ?? []) as PortalMe[])[0];
  if (!me) redirect("/portal/sign-in?ended=ended");
  if (options.consented !== false && !me.electronic) redirect("/portal/consent");
  return me;
}
