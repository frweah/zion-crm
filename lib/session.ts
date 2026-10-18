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
  /**
   * Whether anybody reports to them (0211).
   *
   * Read with the person rather than asked for separately, because the
   * navigation needs it on every page: it is what opens the team's end of
   * day to a manager who is not an Admin.
   */
  manages: boolean;
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
  // network wait fewer on every page.
  //
  // The middleware used to ask the Auth service on every request, which is
  // what caught a signed-out or revoked session promptly. Awaiting that round
  // trip with no timeout is what turned a slow evening into 504s on every
  // request (14 Oct 2026), so it verifies the same way this does and asks the
  // Auth service about once a minute per session instead - revocation is
  // caught within a minute rather than within an hour. The staff row below
  // still has to be active, which is what locks a deactivated person out at
  // once.
  const { data: verified } = await supabase.auth.getClaims();
  const userId = verified?.claims?.sub;
  if (!userId) return null;

  // The person and their live grants together. It was two round trips, and
  // the layout, the page and every section that checks access each made them:
  // cache() above makes it once a request, this makes it one query.
  const { data, error } = (await supabase
    .from("staff")
    .select(
      "id, name, email, role, active, is_system, grants:staff_access_grants!staff_access_grants_staff_id_fkey(area, level, revoked_at), onboarding:staff_onboarding(completed_at)",
    )
    .eq("user_id", userId)
    .eq("active", true)
    .maybeSingle()) as unknown as {
    data:
      | (Omit<CurrentStaff, "grants" | "onboardingOpen" | "isSystem" | "manages"> & {
          is_system: boolean;
          grants: (Grant & { revoked_at: string | null })[] | null;
          onboarding: { completed_at: string | null } | { completed_at: string | null }[] | null;
        })
      | null;
    error: { message: string; code?: string } | null;
  };

  /**
   * No row and an error are not the same thing, and this is where that
   * matters most.
   *
   * Every screen asks this, and null from here means "no access" - so a
   * query that *fails* signs everybody out of everything, silently, and the
   * only symptom is that the whole practice is looking at /no-access. That
   * happened on 18 Oct 2026: an embed PostgREST could not resolve made this
   * select error, and nothing said so.
   *
   * It still returns null, because failing open would be worse. What changes
   * is that the fault is now in the logs with its reason, instead of looking
   * exactly like somebody who was never given an account. The middleware
   * learned the same lesson about revocation: an error is not an answer.
   */
  if (error) {
    console.error("getCurrentStaff could not read the staff row", error.code, error.message);
    return null;
  }
  if (!data) return null;

  /**
   * Whether anybody reports to them.
   *
   * Asked as its own question rather than embedded in the query above, and
   * the reason is worth keeping: `reports:staff!staff_manager_id_fkey(id)`
   * is a self-referencing embed, and PostgREST would not resolve it -
   * "Could not find a relationship between 'staff' and 'staff'". The whole
   * select then failed, getCurrentStaff returned null, and every screen for
   * every role answered /no-access. The smoke test caught it on the way to
   * production and the deploy never promoted (18 Oct 2026).
   *
   * A count over a six-row table, inside a request-cached function, is not
   * worth being clever about.
   */
  const { count } = await supabase
    .from("staff")
    .select("id", { count: "exact", head: true })
    .eq("manager_id", data.id)
    .eq("active", true);

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
    manages: (count ?? 0) > 0,
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
