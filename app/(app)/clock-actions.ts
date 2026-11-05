"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

/**
 * Clocking in and out, from wherever somebody is standing.
 *
 * The button is in the header on every screen, so these are reached from every
 * screen - which is why none of them takes a path to go back to. They
 * revalidate the three places that show a clock figure and let the current
 * page refresh itself.
 *
 * Every rule lives in the database (0293): one session at a time, the break
 * inside it, the hours as the clock less the breaks. These only carry what the
 * person pressed.
 */
export type ClockState = { error: string | null; ok: string | null };

const touched = () => {
  revalidatePath("/time-clock");
  revalidatePath("/my-day");
  revalidatePath("/dashboard");
  revalidatePath("/hours");
};

export async function clockIn(_prev: ClockState): Promise<ClockState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("clock_in", { p_note: "", p_client: null });
  if (error) return { error: error.message, ok: null };

  touched();
  return { error: null, ok: "Clocked in." };
}

export async function startBreak(_prev: ClockState): Promise<ClockState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("start_break");
  if (error) return { error: error.message, ok: null };
  touched();
  return { error: null, ok: "On a break." };
}

export async function endBreak(_prev: ClockState): Promise<ClockState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("end_break");
  if (error) return { error: error.message, ok: null };
  touched();
  return { error: null, ok: "Back on." };
}

/**
 * Clock out.
 *
 * What the time was spent on is not asked for here: the button is in the
 * header and a person pressing it at the end of the day should not be stopped
 * by a form. The session is recorded with the clock on it and the description
 * can be added on the Time clock screen, which is where the fuller entry has
 * always lived.
 */
export async function clockOut(_prev: ClockState, formData?: FormData): Promise<ClockState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("clock_out", {
    p_description: String(formData?.get("description") ?? "").trim(),
    p_category: String(formData?.get("category") ?? "").trim() || null,
    p_at: null,
  });
  if (error) return { error: error.message, ok: null };
  touched();
  return { error: null, ok: "Clocked out." };
}

/** An auto-closed session the person has looked at and agrees with. */
export async function confirmAutoClosed(_prev: ClockState, formData: FormData): Promise<ClockState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("confirm_auto_closed_session", {
    p_session: String(formData.get("session_id") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  touched();
  return { error: null, ok: "Confirmed." };
}
