"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type PayrollState = { error: string | null; ok: string | null };

/** The payroll service staff give their bank details to (0100). A name, never a number. */
export async function savePayrollService(_prev: PayrollState, formData: FormData): Promise<PayrollState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin sets the payroll service.", ok: null };

  const name = String(formData.get("payroll_service") ?? "").trim();
  if (/\d{5,}/.test(name)) return { error: "A name only - no account or client numbers.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase.from("org_settings").update({ payroll_service: name }).eq("id", true).select("id");
  if (error) return { error: error.message, ok: null };
  if (!data?.length) return { error: "The practice settings row is missing.", ok: null };

  revalidatePath("/admin/settings");
  revalidatePath("/paperwork", "layout");
  return { error: null, ok: "Payroll service saved." };
}
