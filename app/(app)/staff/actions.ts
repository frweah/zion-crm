"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";
import { ROLE_NAMES, type Role } from "@/lib/roles";

export type StaffState = { error: string | null; ok: string | null };

/**
 * Invite a staff member.
 *
 * The staff row is created first through the RLS-bound client, so the database
 * confirms the caller really is an Admin. Only the invite email itself needs
 * the service-role key.
 */
export async function inviteStaff(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can add staff.", ok: null };

  const name = String(formData.get("name") ?? "").trim();
  const email = String(formData.get("email") ?? "")
    .trim()
    .toLowerCase();
  const role = String(formData.get("role") ?? "") as Role;

  if (!name || !email) return { error: "Name and email address are both required.", ok: null };
  if (!ROLE_NAMES.includes(role)) return { error: "Choose a role.", ok: null };

  const supabase = await createClient();
  const { error: insertError } = await supabase
    .from("staff")
    .insert({ name, email, role, active: true, invited_at: new Date().toISOString() });

  if (insertError) {
    return {
      error:
        insertError.code === "23505"
          ? "That email address already has a staff account."
          : insertError.message,
      ok: null,
    };
  }

  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  const admin = createAdminClient();
  const { error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo: `${site}/auth/confirm?type=invite`,
  });

  revalidatePath("/staff");

  if (inviteError) {
    return {
      error: `${name} was added, but the invite email failed to send (${inviteError.message}). Use "Resend invite".`,
      ok: null,
    };
  }

  return { error: null, ok: `Invite sent to ${email}.` };
}

export async function resendInvite(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can do that.", ok: null };

  const email = String(formData.get("email") ?? "")
    .trim()
    .toLowerCase();
  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";

  const admin = createAdminClient();
  const { error } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo: `${site}/auth/confirm?type=invite`,
  });

  revalidatePath("/staff");
  return error ? { error: error.message, ok: null } : { error: null, ok: `Invite resent to ${email}.` };
}

/**
 * Deactivate or reactivate an account.
 *
 * Deactivating must remove access immediately (kickoff, Non-negotiables).
 * Flipping the staff row inactive is what does it: every RLS policy runs
 * through is_active_staff(), so the database stops answering for that user
 * on the very next query, even on a still-valid access token. Banning the
 * auth user as well stops them refreshing that token or signing in again.
 *
 * Assigned clients must be reassigned first (spec 3g).
 */
export async function setStaffActive(
  _prev: StaffState,
  formData: FormData,
): Promise<StaffState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can do that.", ok: null };

  const staffId = String(formData.get("staffId") ?? "");
  const active = String(formData.get("active") ?? "") === "true";

  if (staffId === me.id && !active) {
    return { error: "You cannot deactivate your own account.", ok: null };
  }

  const supabase = await createClient();

  if (!active) {
    const { count } = await supabase
      .from("clients")
      .select("*", { count: "exact", head: true })
      .eq("assigned_staff_id", staffId)
      .eq("status", "Active");

    if (count && count > 0) {
      return {
        error: `Reassign this person's ${count} active client${count === 1 ? "" : "s"} before deactivating the account.`,
        ok: null,
      };
    }
  }

  const { data: row, error } = await supabase
    .from("staff")
    .update({ active })
    .eq("id", staffId)
    .select("user_id, name")
    .single();

  if (error) return { error: error.message, ok: null };

  if (row?.user_id) {
    const admin = createAdminClient();
    await admin.auth.admin.updateUserById(row.user_id, {
      ban_duration: active ? "none" : "876000h", // ~100 years
    });
  }

  revalidatePath("/staff");
  return {
    error: null,
    ok: `${row?.name ?? "Account"} ${active ? "reactivated" : "deactivated — access removed"}.`,
  };
}
