"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";

export type UpdateState = { error: string | null; ok: string | null };

/**
 * Posting an update, and saying you have read one (Design language, §3).
 *
 * Reading is its own action with its own button. The alternative - counting
 * somebody as having read a post because it was on their screen - would make
 * the who-has-not-read list worthless, which is the one thing the feature is
 * for.
 */
export async function postUpdate(_prev: UpdateState, formData: FormData): Promise<UpdateState> {
  const me = await requireStaff();
  if (me.role !== "Admin") return { error: "Only an Admin posts an update.", ok: null };

  const title = String(formData.get("title") ?? "").trim();
  const text = String(formData.get("text") ?? "").trim();
  const link = String(formData.get("link") ?? "").trim();
  const audience = formData.getAll("audience").map(String).filter(Boolean);
  if (!title || !text) return { error: "An update has a heading and something to say.", ok: null };
  if (link && !/^https?:\/\//i.test(link)) return { error: "A link starts with http:// or https://.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("updates").insert({
    title,
    text,
    link: link || null,
    audience,
    pinned: formData.get("pinned") === "on",
    requires_ack: formData.get("requires_ack") === "on",
    posted_by: me.id,
    posted_by_name: me.name,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/updates");
  return { error: null, ok: "Posted." };
}

/** "I have read this." One person, one update, once. */
export async function acknowledgeUpdate(formData: FormData): Promise<void> {
  const me = await requireStaff();
  const id = String(formData.get("update_id") ?? "");
  if (!/^[0-9a-f-]{36}$/.test(id)) return;

  const supabase = await createClient();
  await supabase.from("update_reads").upsert({ update_id: id, staff_id: me.id }, { onConflict: "update_id,staff_id" });
  revalidatePath("/updates");
}

/** Taken down: it stops being anybody's to read, and the record of who read it stays. */
export async function retireUpdate(formData: FormData): Promise<void> {
  const me = await requireStaff();
  if (me.role !== "Admin") return;
  const id = String(formData.get("update_id") ?? "");
  if (!/^[0-9a-f-]{36}$/.test(id)) return;

  const supabase = await createClient();
  await supabase.from("updates").update({ active: false, updated_at: new Date().toISOString() }).eq("id", id);
  revalidatePath("/updates");
}
