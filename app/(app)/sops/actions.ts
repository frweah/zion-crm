"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type SopState = { error: string | null; ok: string | null };

function rolesFrom(formData: FormData): string[] {
  // Admin always keeps access, as in the prototype.
  const roles = new Set<string>(["Admin"]);
  for (const r of formData.getAll("roles")) roles.add(String(r));
  return [...roles];
}

export async function createSop(_prev: SopState, formData: FormData): Promise<SopState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can write procedures.", ok: null };

  const title = String(formData.get("title") ?? "").trim();
  const body = String(formData.get("body") ?? "").trim();
  if (!title || !body) return { error: "A procedure needs a title and steps.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("sops")
    .insert({ title, body, roles: rolesFrom(formData), sort_order: 100 });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/sops");
  return { error: null, ok: `"${title}" added.` };
}

export async function updateSop(_prev: SopState, formData: FormData): Promise<SopState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can edit procedures.", ok: null };

  const id = String(formData.get("sop_id") ?? "");
  const title = String(formData.get("title") ?? "").trim();
  const body = String(formData.get("body") ?? "").trim();
  if (!title || !body) return { error: "A procedure needs a title and steps.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("sops")
    .update({ title, body, roles: rolesFrom(formData) })
    .eq("id", id);

  if (error) return { error: error.message, ok: null };

  revalidatePath("/sops");
  return { error: null, ok: "Saved." };
}
