"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";
import { ROLE_NAMES, ORG, type Role } from "@/lib/roles";
import { sendEmail, emailConfigured } from "@/lib/email";

export type StaffState = { error: string | null; ok: string | null };

/**
 * The invite email. Somebody being onboarded is told so, and what to have to
 * hand; the link itself is Supabase's, made here rather than sent by Supabase
 * so the words are ours. Without Resend configured, Supabase sends its own.
 */
async function sendInvite(email: string, name: string, onboarding: boolean): Promise<string | null> {
  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  const admin = createAdminClient();
  if (!emailConfigured()) {
    const { error } = await admin.auth.admin.inviteUserByEmail(email, { redirectTo: `${site}/auth/confirm` });
    return error?.message ?? null;
  }
  const { data, error } = await admin.auth.admin.generateLink({
    type: "invite",
    email,
    options: { redirectTo: `${site}/auth/confirm` },
  });
  if (error || !data?.properties?.action_link) return error?.message ?? "no link was made";

  const first = name.split(" ")[0];
  const result = await sendEmail({
    to: email,
    subject: onboarding ? `Welcome to ${ORG.name} - complete your onboarding` : `Your ${ORG.name} CRM account`,
    text: [
      `${first},`,
      "",
      `You have been given an account on the ${ORG.name} CRM. Open this link to choose your password:`,
      "",
      data.properties.action_link,
      "",
      ...(onboarding
        ? [
            "Once you are in, the CRM takes you through onboarding, in six short steps:",
            "  1. your personal details and an emergency contact",
            "  2. your identity documents (a scan or photo; the originals are checked in person)",
            "  3. any certifications you hold - CPR, ACRE, a background check - with their expiry dates",
            "  4. your tax form",
            "  5. the data-handling policy, signed in the app",
            "  6. how you would like to be paid (bank details go to the payroll service, never to us)",
            "",
            "Please complete it before your first day. You can stop and pick up where you left off.",
            "",
          ]
        : []),
      "The link works once and expires. If it has, ask the administrator to send a new one.",
      "",
      ORG.name,
      `${ORG.phone} · ${ORG.email}`,
    ].join("\n"),
  });
  return result.ok ? null : result.error;
}

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
  const engagement = String(formData.get("employment_type") ?? "");
  const startedOn = String(formData.get("started_on") ?? "").trim();

  if (!name || !email) return { error: "Name and email address are both required.", ok: null };
  if (!ROLE_NAMES.includes(role)) return { error: "Choose a role.", ok: null };
  if (engagement !== "Employee" && engagement !== "Contractor") {
    return { error: "Say whether they are an employee or a contractor - it decides their tax form and I-9.", ok: null };
  }

  const supabase = await createClient();
  const { data: added, error: insertError } = await supabase
    .from("staff")
    .insert({ name, email, role, active: true, invited_at: new Date().toISOString() })
    .select("id")
    .single();

  if (insertError) {
    return {
      error:
        insertError.code === "23505"
          ? "That email address already has a staff account."
          : insertError.message,
      ok: null,
    };
  }

  // How they are engaged, and the walkthrough that follows from it (0100).
  const [{ error: employmentError }, { error: onboardingError }] = await Promise.all([
    supabase.from("staff_employment").insert({ staff_id: added.id, employment_type: engagement, started_on: startedOn || null }),
    supabase.from("staff_onboarding").insert({ staff_id: added.id }),
  ]);

  const inviteError = await sendInvite(email, name, true);

  revalidatePath("/admin/people", "layout"); // the People page and each person's record under it

  if (employmentError || onboardingError) {
    return {
      error: `${name} was added, but their onboarding was not set up (${(employmentError ?? onboardingError)?.message}).`,
      ok: null,
    };
  }
  if (inviteError) {
    return {
      error: `${name} was added, but the invite email failed to send (${inviteError}). Use "Resend invite".`,
      ok: null,
    };
  }

  return { error: null, ok: `Invite sent to ${email}, asking them to complete onboarding.` };
}

export async function resendInvite(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can do that.", ok: null };

  const email = String(formData.get("email") ?? "")
    .trim()
    .toLowerCase();
  const supabase = await createClient();
  const { data: person } = await supabase
    .from("staff")
    .select("name, onboarding:staff_onboarding(completed_at)")
    .eq("email", email)
    .maybeSingle();
  const ob = person ? (Array.isArray(person.onboarding) ? person.onboarding[0] : person.onboarding) : null;
  const error = await sendInvite(email, person?.name ?? email, Boolean(ob && !ob.completed_at));

  revalidatePath("/admin/people", "layout"); // the People page and each person's record under it
  return error ? { error, ok: null } : { error: null, ok: `Invite resent to ${email}.` };
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

  revalidatePath("/admin/people", "layout"); // the People page and each person's record under it
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

  revalidatePath("/admin/people", "layout"); // the People page and each person's record under it
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
