"use server";

import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type DropState = { error: string | null; id?: string; name?: string };

/**
 * A file dragged or pasted into a thread.
 *
 * The browser puts the bytes in storage itself and then says what it put
 * there - the same division as the client record and the staff file, because a
 * 50 MB file cannot go through a server action and never could. This records
 * it, and `record_chat_file` is where the rules are checked: the path has to
 * be in this thread, the person has to be in it, and the type has to be one
 * the practice accepts, which it reads off the bucket rather than keeping a
 * second list of its own.
 *
 * It is internal. The file is on the thread and on nobody's record until
 * somebody files it on a client, and attaching it to a message is still by
 * reference (0273).
 */
export async function recordDroppedFile(
  path: string,
  conversationId: string,
  filename: string,
  mime: string,
  size: number,
): Promise<DropState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in." };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("record_chat_file", {
    p_conversation: conversationId,
    p_path: path,
    p_filename: filename,
    p_mime: mime,
    p_size: size,
  });
  if (error) return { error: error.message };
  return { error: null, id: String(data), name: filename };
}
