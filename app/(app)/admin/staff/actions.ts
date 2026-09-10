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
    redirectTo: `${site}/auth/confirm`,
  });

  revalidatePath("/admin/staff");

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
    redirectTo: `${site}/auth/confirm`,
  });

  revalidatePath("/admin/staff");
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

  revalidatePath("/admin/staff");
  return {
    error: null,
    ok: `${row?.name ?? "Account"} ${active ? "reactivated" : "deactivated — access removed"}.`,
  };
}

/**
 * Offboard somebody, in one act.
 *
 * The database does the reassignment, the record and the deactivation in one
 * transaction. This does the one thing it cannot: banning the auth user, which
 * lives outside the database. If that call fails the account is already
 * inactive, so row-level security has already shut the door — the ban is
 * belt to that braces.
 */
export async function offboardStaff(
  _prev: StaffState,
  formData: FormData,
): Promise<StaffState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can do that.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const staffId = str("staff_id");
  const lastDay = str("last_day");
  const successor = str("successor_id") || null;

  if (!staffId || !lastDay) return { error: "Who, and when was their last day?", ok: null };

  const supabase = await createClient();

  const { data, error } = await supabase.rpc("offboard_staff", {
    p_staff_id: staffId,
    p_last_day: lastDay,
    p_reason: str("reason"),
    p_successor: successor,
    p_note: str("note"),
  });

  if (error) return { error: error.message, ok: null };

  const result = Array.isArray(data) ? data[0] : null;

  const { data: row } = await supabase
    .from("staff")
    .select("user_id, name")
    .eq("id", staffId)
    .maybeSingle();

  if (row?.user_id) {
    const admin = createAdminClient();
    await admin.auth.admin.updateUserById(row.user_id, { ban_duration: "876000h" });
  }

  revalidatePath("/admin/staff");
  revalidatePath("/clients");
  revalidatePath("/insights/capacity");

  const moved = Number(result?.clients_moved ?? 0);
  const tasks = Number(result?.tasks_moved ?? 0);

  return {
    error: null,
    ok:
      `${row?.name ?? "They"} have been offboarded and their access is gone. ` +
      (moved > 0
        ? `${moved} client${moved === 1 ? "" : "s"}${tasks > 0 ? ` and ${tasks} task${tasks === 1 ? "" : "s"}` : ""} ${successor ? "moved across" : "left unassigned"}.`
        : "They had no active clients."),
  };
}
