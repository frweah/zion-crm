"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { parseFilters, toParams, toQuery } from "@/lib/list-filters";
import type { Json } from "@/lib/database.types";

export type ViewState = { error: string | null; ok: string | null };

/**
 * Save the current filters as a named view.
 *
 * Shared views (visible to everyone) are Admin's to make; anyone can keep
 * their own. The database enforces that, not this function.
 */
export async function saveView(_prev: ViewState, formData: FormData): Promise<ViewState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { error: "Give the view a name.", ok: null };

  const screen = String(formData.get("screen") ?? "clients");
  const shared = formData.get("shared") === "on";
  if (shared && me.role !== "Admin") {
    return { error: "Only Admin can create a view the whole team sees.", ok: null };
  }

  // Reconstruct the filters from the query string the form carries, so what is
  // saved is exactly what the person is looking at.
  const raw = Object.fromEntries(new URLSearchParams(String(formData.get("query") ?? "")));
  const query = new URLSearchParams(String(formData.get("query") ?? ""));
  const multi: Record<string, string[]> = {};
  for (const key of query.keys()) multi[key] = query.getAll(key);
  const filters = parseFilters({ ...raw, ...multi });

  const supabase = await createClient();
  const { error } = await supabase.from("saved_views").insert({
    screen,
    name,
    owner_staff_id: shared ? null : me.id,
    params: toParams(filters) as Json,
    created_by: me.id,
  });

  if (error) {
    return {
      error:
        error.code === "23505"
          ? `You already have a view called "${name}".`
          : error.message,
      ok: null,
    };
  }

  revalidatePath(`/${screen}`);
  return { error: null, ok: `Saved "${name}".` };
}

export async function deleteView(_prev: ViewState, formData: FormData): Promise<ViewState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("view_id") ?? "");
  const screen = String(formData.get("screen") ?? "clients");

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("saved_views")
    .delete()
    .eq("id", id)
    .select("name")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) {
    return { error: "That view belongs to someone else, or is a shared one only Admin can remove.", ok: null };
  }

  revalidatePath(`/${screen}`);
  return { error: null, ok: `Removed "${data.name}".` };
}

/**
 * Open a saved view: remember it as this person's last, then redirect to the
 * URL it represents. The view is a set of filters, so applying it is just
 * navigating to them.
 */
export async function applyView(formData: FormData): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) redirect("/login");

  const id = String(formData.get("view_id") ?? "");
  const screen = String(formData.get("screen") ?? "clients");

  const supabase = await createClient();

  if (!id) {
    await supabase
      .from("staff_prefs")
      .upsert({ staff_id: me.id, key: `last_view:${screen}`, value: null as unknown as Json });
    redirect(`/${screen}`);
  }

  const { data: view } = await supabase
    .from("saved_views")
    .select("params")
    .eq("id", id)
    .maybeSingle();

  if (!view) redirect(`/${screen}`);

  await supabase.from("staff_prefs").upsert({
    staff_id: me.id,
    key: `last_view:${screen}`,
    value: id as unknown as Json,
  });

  const q = toQuery(parseFilters(view.params as Record<string, unknown>));
  redirect(q ? `/${screen}?${q}&view=${id}` : `/${screen}?view=${id}`);
}
