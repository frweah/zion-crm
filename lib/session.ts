import "server-only";
import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { Grant, Role } from "@/lib/roles";

export type CurrentStaff = {
  id: string;
  name: string;
  email: string;
  role: Role;
  active: boolean;
  /** Areas given to them beyond their role (0092). Only ever adds. */
  grants: Grant[];
  /**
   * Brought on through the onboarding walkthrough (0100) and not finished it.
   * False for everybody who joined before it, and once it is done.
   */
  onboardingOpen: boolean;
  /** Not a person: the deploy check (0120). Reads only; never onboarded. */
  isSystem: boolean;
};

/**
 * The signed-in staff member, or null.
 *
 * Returns null for a logged-in auth user with no active staff row — a
 * deactivated account, or someone who signed up outside the invite flow.
 * RLS enforces the same thing at the database; this is what the UI reads.
 */
export const getCurrentStaff = cache(async (): Promise<CurrentStaff | null> => {
  const supabase = await createClient();

  // Verified here against the project's published signing key (ES256, cached
  // for ten minutes per server) rather than by asking the Auth service - one
  // network wait fewer on every page. The middleware still asks the Auth
  // service on every request, which is what catches a signed-out or revoked
  // session; and the staff row below still has to be active.
  const { data: verified } = await supabase.auth.getClaims();
  const userId = verified?.claims?.sub;
  if (!userId) return null;

  // The person and their live grants together. It was two round trips, and
  // the layout, the page and every section that checks access each made them:
  // cache() above makes it once a request, this makes it one query.
  const { data } = (await supabase
    .from("staff")
    .select(
      "id, name, email, role, active, is_system, grants:staff_access_grants!staff_access_grants_staff_id_fkey(area, level, revoked_at), onboarding:staff_onboarding(completed_at)",
    )
    .eq("user_id", userId)
    .eq("active", true)
    .maybeSingle()) as unknown as {
    data:
      | (Omit<CurrentStaff, "grants" | "onboardingOpen" | "isSystem"> & {
          is_system: boolean;
          grants: (Grant & { revoked_at: string | null })[] | null;
          onboarding: { completed_at: string | null } | { completed_at: string | null }[] | null;
        })
      | null;
  };
  if (!data) return null;

  // Only live ones; the database ends them when somebody is made inactive.
  const grants = (data.grants ?? []).filter((g) => !g.revoked_at).map(({ area, level }) => ({ area, level }));
  const onboarding = Array.isArray(data.onboarding) ? (data.onboarding[0] ?? null) : data.onboarding;
  return {
    id: data.id,
    name: data.name,
    email: data.email,
    role: data.role,
    active: data.active,
    grants,
    onboardingOpen: onboarding !== null && onboarding.completed_at === null,
    isSystem: Boolean(data.is_system),
  };
});

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
