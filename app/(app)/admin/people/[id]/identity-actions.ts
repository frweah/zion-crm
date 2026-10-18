"use server";

import { revalidatePath } from "next/cache";
import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ROLE_NAMES, type Role } from "@/lib/roles";

/**
 * Who somebody is, on their record (owner, 14 Oct 2026, item 4).
 *
 * "Admin can edit every field on a staff record - name, email, phone,
 * aliases, role, employment type, start date, pay."
 *
 * Employment type, start date and pay already had forms of their own on this
 * screen. These are the four that had none: a person's name, the address they
 * sign in with, their phone number, and their role. Until now the only way to
 * correct a misspelled name was in the database.
 *
 * Every change here is written to staff_record_changes by a trigger (0199),
 * with who made it and whether it was somebody else's record - so the log is
 * the same whether the change came from this form, a sweep or the console.
 * The note below rides along with it.
 *
 * What is deliberately not here: signing somebody's tax form or policy, and
 * giving their texting or e-delivery consent. Those are refused by the
 * database (0200), not merely left off the screen.
 */
export type IdentityState = { error: string | null; ok: string | null };

async function adminHands() {
  const me = await requireAdmin();
  return { me, supabase: await createClient() };
}

/** The reason rides with the change, in the same transaction. */
async function withNote<T>(
  supabase: Awaited<ReturnType<typeof createClient>>,
  note: string,
  run: () => Promise<T>,
): Promise<T> {
  // set_config with is_local = false: a server action is one request on one
  // connection, and the trigger reads it during the write that follows.
  await supabase.rpc("set_staff_change_note", { p_note: note });
  try {
    return await run();
  } finally {
    await supabase.rpc("set_staff_change_note", { p_note: "" });
  }
}

export async function editStaffIdentity(
  _prev: IdentityState,
  formData: FormData,
): Promise<IdentityState> {
  const { supabase } = await adminHands();
  const id = String(formData.get("staff_id") ?? "");
  const str = (k: string) => String(formData.get(k) ?? "").trim();

  const name = str("name");
  const email = str("email");
  const phone = str("phone");
  const role = str("role");
  const note = str("note");
  const manager = str("manager_id");

  if (!name) return { error: "A name is required.", ok: null };
  // Nobody manages themselves. The database would take it and the end-of-day
  // summary would be sent to the person who wrote it.
  if (manager && manager === id) {
    return { error: "Somebody cannot be their own manager.", ok: null };
  }
  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return { error: "That address does not look like an email.", ok: null };
  }
  if (!ROLE_NAMES.includes(role as Role)) return { error: "That is not a role.", ok: null };

  const { error } = await withNote(supabase, note, async () =>
    supabase
      .from("staff")
      .update({
        name,
        email: email || null,
        phone: phone || null,
        role,
        // Who they report to: the end-of-day report's assigned manager
        // (0211). Their summaries go to this person and to Admin, and this
        // person can read their days.
        manager_id: manager || null,
      })
      .eq("id", id),
  );
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/admin/people/${id}`);
  revalidatePath("/admin/people");
  return {
    error: null,
    ok: "Saved, and written to this record's history with your name on it.",
  };
}

/**
 * Another address somebody is written to.
 *
 * Never their sign-in address: that stays on the staff row, because it is
 * what Supabase Auth matches and changing it would lock them out. The
 * database refuses an alias that is already somebody's sign-in, so two
 * records can never answer to one address.
 */
export async function addStaffAlias(
  _prev: IdentityState,
  formData: FormData,
): Promise<IdentityState> {
  const { me, supabase } = await adminHands();
  const id = String(formData.get("staff_id") ?? "");
  const address = String(formData.get("address") ?? "").trim();
  const note = String(formData.get("note") ?? "").trim();

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(address)) {
    return { error: "That address does not look like an email.", ok: null };
  }

  const { error } = await supabase
    .from("staff_emails")
    .insert({ staff_id: id, address, note, added_by: me.id });
  if (error) {
    // The database's own words: it knows whose address it already is.
    return { error: error.message.replace(/^.*?:\s*/, "").trim() || error.message, ok: null };
  }

  revalidatePath(`/admin/people/${id}`);
  return { error: null, ok: `Mail to ${address} now reaches them.` };
}

export async function removeStaffAlias(
  _prev: IdentityState,
  formData: FormData,
): Promise<IdentityState> {
  const { supabase } = await adminHands();
  const id = String(formData.get("staff_id") ?? "");
  const aliasId = String(formData.get("alias_id") ?? "");

  const { error } = await supabase.from("staff_emails").delete().eq("id", aliasId);
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/admin/people/${id}`);
  return { error: null, ok: "Removed." };
}
