import { createClient } from "@/lib/supabase/server";
import { TwoFactorRoster, type RosterRow } from "./roster";

/**
 * Who has a second factor, and the switch (0217).
 *
 * The roster is the thing that makes turning it on safe: an Admin can see
 * who is still to enrol before they require it of everybody, rather than
 * finding out on Monday morning.
 */
export default async function SecuritySection() {
  const supabase = await createClient();

  const [{ data: roster }, { data: settings }] = await Promise.all([
    supabase.rpc("two_factor_roster"),
    supabase.from("org_settings").select("require_two_factor").maybeSingle(),
  ]);

  const rows: RosterRow[] = (roster ?? []).map((r) => ({
    staffId: r.staff_id ?? "",
    name: r.name ?? "",
    role: r.role ?? "",
    enrolled: Boolean(r.enrolled),
    enrolledAt: r.enrolled_at ?? null,
  }));

  return <TwoFactorRoster rows={rows} required={Boolean(settings?.require_two_factor)} />;
}
