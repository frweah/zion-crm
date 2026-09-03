import "server-only";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { Role } from "@/lib/roles";

export type CurrentStaff = {
  id: string;
  name: string;
  email: string;
  role: Role;
  active: boolean;
};

/**
 * The signed-in staff member, or null.
 *
 * Returns null for a logged-in auth user with no active staff row — a
 * deactivated account, or someone who signed up outside the invite flow.
 * RLS enforces the same thing at the database; this is what the UI reads.
 */
export async function getCurrentStaff(): Promise<CurrentStaff | null> {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data } = await supabase
    .from("staff")
    .select("id, name, email, role, active")
    .eq("user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  return (data as CurrentStaff | null) ?? null;
}

/** Use in any page that requires a live account. */
export async function requireStaff(): Promise<CurrentStaff> {
  const staff = await getCurrentStaff();
  if (!staff) redirect("/no-access");
  return staff;
}

export async function requireAdmin(): Promise<CurrentStaff> {
  const staff = await requireStaff();
  if (staff.role !== "Admin") redirect("/dashboard");
  return staff;
}
