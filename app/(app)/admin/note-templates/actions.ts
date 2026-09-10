"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { NOTE_TYPES } from "@/lib/constants";

export type TemplateState = { error: string | null; ok: string | null };

/**
 * Change the headings an activity type starts with.
 *
 * Admin only, and the database says so too — this is the practice's
 * documentation standard, and a standard that anybody can edit is a habit.
 *
 * Saving an empty body switches the template off rather than storing nothing.
 * The wording is kept, so turning it back on does not mean writing it again,
 * and notes already written are untouched either way: a note is its text.
 */
export async function saveNoteTemplate(
  _prev: TemplateState,
  formData: FormData,
): Promise<TemplateState> {
  const me = await getCurrentStaff();
  if (!me || me.role !== "Admin") {
    return { error: "Only Admin changes the note headings.", ok: null };
  }

  const noteType = String(formData.get("note_type") ?? "");
  if (!(NOTE_TYPES as readonly string[]).includes(noteType)) {
    return { error: "That is not an activity type.", ok: null };
  }

  const body = String(formData.get("body") ?? "").replace(/\r\n/g, "\n");
  const blank = body.trim() === "";

  const supabase = await createClient();

  if (blank) {
    // Off, not gone. An update rather than an upsert, because there is no
    // wording to keep for a type that never had a template.
    const { error } = await supabase
      .from("note_templates")
      .update({ active: false, updated_by: me.id })
      .eq("note_type", noteType);
    if (error) return { error: error.message, ok: null };

    revalidatePath("/admin/note-templates");
    return { error: null, ok: `${noteType} notes now start with an empty box.` };
  }

  const { error } = await supabase.from("note_templates").upsert(
    { note_type: noteType, body, active: true, updated_by: me.id },
    { onConflict: "note_type" },
  );
  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/note-templates");
  revalidatePath("/clients", "layout");
  return { error: null, ok: `Saved. New ${noteType.toLowerCase()} notes start with this.` };
}
