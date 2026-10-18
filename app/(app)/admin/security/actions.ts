"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";

export type SecurityState = { error: string | null; ok: string | null };

/**
 * Take somebody's second factor off, so they can set up a new one.
 *
 * The lost-phone path, and the reason the practice can require a second
 * factor at all: without it one dropped phone locks somebody out of their
 * work permanently and there is nothing anybody can do about it.
 *
 * Admin only, and never their own — an administrator who could clear their
 * own factor has a second factor that is one click of their own password
 * away from not existing.
 */
export async function clearSecondFactor(
  _prev: SecurityState,
  formData: FormData,
): Promise<SecurityState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can do that.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "");
  if (!staffId) return { error: "Whose?", ok: null };
  if (staffId === me.id) {
    return {
      error:
        "You cannot take off your own. Change it from Two-step sign-in, or ask the other administrator.",
      ok: null,
    };
  }

  const supabase = await createClient();
  const { data: person } = await supabase
    .from("staff")
    .select("name, user_id")
    .eq("id", staffId)
    .maybeSingle();

  if (!person?.user_id) return { error: "That person has no sign-in to change.", ok: null };

  const admin = createAdminClient();
  const { data: factors, error: listError } = await admin.auth.admin.mfa.listFactors({
    userId: person.user_id,
  });
  if (listError) return { error: `Their factors could not be read: ${listError.message}`, ok: null };

  const theirs = factors?.factors ?? [];
  if (theirs.length === 0) {
    return { error: `${person.name} has no second factor set up.`, ok: null };
  }

  for (const factor of theirs) {
    const { error } = await admin.auth.admin.mfa.deleteFactor({
      id: factor.id,
      userId: person.user_id,
    });
    if (error) return { error: `That did not come off: ${error.message}`, ok: null };
  }

  revalidatePath("/admin/system");
  return {
    error: null,
    ok: `${person.name} can set up a new one next time they sign in. Tell them it is off, so they know it was you.`,
  };
}

/** Turn the requirement on or off for the whole practice. */
export async function setTwoFactorRequired(
  _prev: SecurityState,
  formData: FormData,
): Promise<SecurityState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can do that.", ok: null };

  const on = formData.get("required") === "on";
  const supabase = await createClient();

  // Turning it on with people un-enrolled does not lock them out — they are
  // walked through setting one up — but it does mean six people setting up an
  // authenticator at nine on a Monday, so the screen says who is left.
  const { error } = await supabase
    .from("org_settings")
    .update({ require_two_factor: on })
    .not("id", "is", null);

  if (error) return { error: error.message, ok: null };

  revalidatePath("/", "layout");
  return {
    error: null,
    ok: on
      ? "On. Anybody without one is asked to set it up before they can go on."
      : "Off. Anybody who has set one up still uses it.",
  };
}
