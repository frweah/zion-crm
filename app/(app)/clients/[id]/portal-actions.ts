"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type PortalAdminState = { error: string | null; ok: string | null };

const text = (formData: FormData, key: string): string | null => {
  const value = String(formData.get(key) ?? "").trim();
  return value || null;
};

/**
 * Giving, and taking away, a client's portal access. Who may do it, and what a
 * guardian needs, is decided by the database (portal_invite and friends, 0087);
 * these only pass the form along and say what happened.
 */
export async function givePortalAccess(_prev: PortalAdminState, formData: FormData): Promise<PortalAdminState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const kind = formData.get("kind") === "Guardian" ? "Guardian" : "Client";

  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_invite", {
    p_client: clientId,
    p_kind: kind,
    p_name: kind === "Guardian" ? text(formData, "name") : null,
    p_relationship: text(formData, "relationship") ?? "",
    p_phone: text(formData, "phone"),
    p_email: text(formData, "email"),
    p_attachment: kind === "Guardian" ? text(formData, "attachment_id") : null,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  return {
    error: null,
    ok: "Portal access given. Nothing has been sent: tell them how to sign in.",
  };
}

export async function turnOffPortalAccess(_prev: PortalAdminState, formData: FormData): Promise<PortalAdminState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_disable_account", {
    p_account: String(formData.get("account_id") ?? ""),
    p_reason: String(formData.get("reason") ?? ""),
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: "Portal access turned off, and every session for it ended." };
}

export async function signOutOfPortal(_prev: PortalAdminState, formData: FormData): Promise<PortalAdminState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("portal_sign_out_everywhere", { p_client: clientId });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  const n = Number(data ?? 0);
  return {
    error: null,
    ok: n === 0 ? "Nobody was signed in to the portal." : `Signed out of ${n} portal ${n === 1 ? "session" : "sessions"}.`,
  };
}
