import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

/**
 * What a service is priced at, read from the schedule Admin can change
 * (Billing Simplification Brief §13.13).
 *
 * "The rate comes from the schedule and never from a constant in the code."
 * There used to be a hard-coded copy in the add form, and it said Job
 * Development with the HQ indicator was 560 when the schedule says 1,120 - so
 * the form offered half the rate for a service the practice bills monthly.
 *
 * This moved out of the Billing page when the client's own Billing tab grew
 * the same form: two screens building the same map from the same table is two
 * places for that mistake to come back.
 */
export type ServiceRate = { fee: number; rateType: "Hourly" | "Flat Fee"; basis: string };

export async function readRateSchedule(
  supabase: SupabaseClient<Database>,
): Promise<Record<string, ServiceRate>> {
  const { data } = await supabase
    .from("rate_schedule")
    .select("crm_service, fee, unit, service, sub")
    .not("crm_service", "is", null);

  // One entry per service: every row that prices a service carries the same
  // fee and unit, so the last one read is the figure.
  const rates: Record<string, ServiceRate> = {};
  for (const r of data ?? []) {
    if (!r.crm_service) continue;
    rates[r.crm_service] = {
      fee: Number(r.fee),
      rateType: r.unit === "per hour" ? "Hourly" : "Flat Fee",
      basis: `The rate schedule: ${r.service}${r.sub ? `, ${r.sub}` : ""}`,
    };
  }
  return rates;
}
