import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { NOTE_TYPES } from "@/lib/constants";
import { TemplateEditor } from "./template-editor";

/**
 * Note headings.
 *
 * The practice's documentation standard, in the only form that gets followed:
 * already in the box when somebody starts writing.
 *
 * Every activity type is listed, including the ones with no headings, because
 * "this type starts blank" is a decision somebody made and should be visible
 * as one rather than looking like a type that was forgotten.
 */
export default async function NoteTemplatesPage() {
  const me = await requireStaff();
  if (me.role !== "Admin") redirect("/dashboard");

  const supabase = await createClient();
  const { data } = await supabase
    .from("note_templates")
    .select("note_type, body, active, updated_at");

  const held = new Map((data ?? []).map((t) => [t.note_type, t]));

  return (
    <>
      <h1 className="h1">Note headings</h1>
      <p className="sub">What a new note of each type starts with</p>

      <div className="card" style={{ marginTop: 14 }}>
        <p style={{ margin: 0 }}>
          When somebody picks an activity type, these headings appear in the note box. They are a
          starting point and nothing more — every one can be changed or deleted while writing, and
          nothing here is required.
        </p>
        <p className="lock" style={{ marginBottom: 0 }}>
          Headings are never written over text somebody has already typed. Changing these does not
          alter a single note already written.
        </p>
      </div>

      {NOTE_TYPES.map((t) => {
        const row = held.get(t);
        return (
          <TemplateEditor
            key={t}
            noteType={t}
            body={row?.body ?? ""}
            active={Boolean(row?.active)}
            updatedAt={row?.updated_at ?? null}
          />
        );
      })}
    </>
  );
}
