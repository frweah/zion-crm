"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type FileState = { error: string | null; ok: string | null };

/**
 * The three things a person can do with something waiting to be filed
 * (item E).
 *
 * Every one of them is a database function that says who did it: the table
 * has no write policy, the same way payments and the invoice ledger have
 * none. Confirming is the only one that writes anything onto a client's
 * record, which is what makes "unconfirmed never appears in a report" true
 * rather than remembered - there is nothing to leave out.
 */
async function hands() {
  const me = await getCurrentStaff();
  if (!me) return null;
  return me;
}

export async function assignToFile(_prev: FileState, formData: FormData): Promise<FileState> {
  if (!(await hands())) return { error: "You are not signed in.", ok: null };
  const item = String(formData.get("item") ?? "");
  const client = String(formData.get("client_id") ?? "");
  if (!client) return { error: "Choose the client it was about.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("to_file_assign", { p_item: item, p_client: client });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/my-day");
  return { error: null, ok: "Assigned. Confirm it to put it on the record." };
}

export async function confirmToFile(_prev: FileState, formData: FormData): Promise<FileState> {
  if (!(await hands())) return { error: "You are not signed in.", ok: null };
  const item = String(formData.get("item") ?? "");
  const outcome = String(formData.get("outcome") ?? "");
  const note = String(formData.get("note") ?? "").trim();
  const category = String(formData.get("category") ?? "").trim();

  const supabase = await createClient();
  const { error } = await supabase.rpc("to_file_confirm", {
    p_item: item,
    p_outcome: outcome,
    p_note: note || undefined,
    p_category: category || undefined,
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/my-day");
  return {
    error: null,
    ok:
      outcome === "happened"
        ? "On the record, and in the next report."
        : outcome === "wrong client"
          ? "Back in your inbox with the guess removed — say whose it was."
          : "Recorded as not having happened. Nothing went on the record.",
  };
}

export async function discardToFile(_prev: FileState, formData: FormData): Promise<FileState> {
  if (!(await hands())) return { error: "You are not signed in.", ok: null };
  const item = String(formData.get("item") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();

  const supabase = await createClient();
  const { error } = await supabase.rpc("to_file_discard", { p_item: item, p_reason: reason });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/my-day");
  return { error: null, ok: "Discarded. Nothing was written about anybody." };
}
