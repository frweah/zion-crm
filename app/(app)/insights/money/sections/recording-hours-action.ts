"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type MoneyState = { error: string | null; ok: string | null };

/**
 * How many hours of recording the practice will pay to read, per person per
 * month (item F).
 *
 * The write goes to `org_settings`, which only Admin may update — the
 * database says so, not this file. A number outside what a month could
 * plausibly hold is refused here, because a typed 200 that meant 20 is the
 * mistake this field is most likely to suffer and it costs money.
 */
export async function setRecordingHours(_prev: MoneyState, formData: FormData): Promise<MoneyState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const hours = Number(String(formData.get("hours") ?? "").trim());
  if (!Number.isInteger(hours) || hours < 0 || hours > 200) {
    return { error: "Give a whole number of hours, up to 200.", ok: null };
  }

  const supabase = await createClient();
  const { data: row } = await supabase.from("org_settings").select("id").maybeSingle();
  if (!row) return { error: "There are no practice settings to change.", ok: null };

  const { error } = await supabase
    .from("org_settings")
    .update({ recording_hours_per_person: hours })
    .eq("id", row.id);
  if (error) return { error: error.message, ok: null };

  revalidatePath("/insights/money");
  return {
    error: null,
    ok:
      hours === 0
        ? "Nothing more will be read this month or any month until this is raised."
        : `${hours} hours a person a month. Recordings already held stay held until somebody lets one through.`,
  };
}
