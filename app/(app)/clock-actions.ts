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
 * Kept for the forms that post to it - the Time clock screen's own entry -
 * while the header asks for the day's account through `clockOutWith` below.
 */
export async function clockOut(_prev: ClockState, formData?: FormData): Promise<ClockState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("clock_out", {
    p_description: String(formData?.get("description") ?? "").trim(),
    p_category: String(formData?.get("category") ?? "").trim() || null,
    p_at: null,
    p_client: null,
    p_staff_file: null,
    p_attachment: null,
  });
  if (error) return { error: error.message, ok: null };
  touched();
  return { error: null, ok: "Clocked out." };
}

/** What the clock-out panel offers: the person's own work categories, and who is on the board. */
export type ClockChoices = {
  categories: { key: string; label: string }[];
  clients: { id: string; name: string }[];
};

/**
 * The lists the panel fills its two dropdowns from.
 *
 * Fetched when the panel opens rather than carried by the header. The header
 * is on every screen in the practice, and a query per page load to fill a
 * dropdown nobody has opened is paid for on every screen all day.
 */
export async function summaryChoices(): Promise<ClockChoices> {
  const me = await getCurrentStaff();
  if (!me) return { categories: [], clients: [] };

  const supabase = await createClient();
  const [{ data: categories }, { data: clients }] = await Promise.all([
    supabase.rpc("work_categories_for", { p_role: me.role }),
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
  ]);
  return {
    categories: (categories ?? [])
      .filter((c) => c.key !== null)
      .map((c) => ({ key: String(c.key), label: String(c.label ?? c.key) })),
    clients: (clients ?? []).map((c) => ({ id: c.id, name: c.name })),
  };
}

/**
 * Clock out, with the day's account.
 *
 * The file is already up by the time this is called - the browser puts the
 * bytes in storage itself, as every other upload in the practice does, so
 * that a 20 MB scan does not go through a server action with a 4.5 MB
 * ceiling on it (check-upload-limits).
 *
 * Nothing here is required. An empty account is a clock-out, and the day is
 * flagged until somebody says what it was.
 */
export async function clockOutWith(said: {
  description: string;
  category: string;
  client: string;
  staffFile: string | null;
  attachment: string | null;
}): Promise<ClockState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("clock_out", {
    p_description: said.description.trim(),
    p_category: said.category.trim() || null,
    p_at: null,
    p_client: said.client || null,
    p_staff_file: said.staffFile,
    p_attachment: said.attachment,
  });
  if (error) return { error: error.message, ok: null };
  touched();
  revalidatePath("/end-of-day");
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
