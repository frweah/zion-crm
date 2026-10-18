"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { dateComplaint } from "@/lib/constants";

export type BaselineState = { error: string | null; ok: string | null };

/**
 * Write down where the practice stood, as at a day.
 *
 * The counting is the database's, from the same views the screen above
 * reads, so the snapshot and the screen cannot disagree on the day it is
 * taken. This checks the date is one somebody meant and passes it on.
 */
export async function takeBaseline(
  _prev: BaselineState,
  formData: FormData,
): Promise<BaselineState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can do that.", ok: null };

  const asOf = String(formData.get("as_of") ?? "").trim();
  const wrong = dateComplaint(asOf, "That day");
  if (wrong) return { error: wrong, ok: null };
  if (!asOf) return { error: "As at which day?", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("take_money_baseline", {
    p_as_of: asOf,
    p_label: String(formData.get("label") ?? "").trim(),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/insights/money");
  return { error: null, ok: `Counted and kept, as at ${asOf}.` };
}
