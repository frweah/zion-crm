"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { can } from "@/lib/roles";

/**
 * Ask the agent for an extra pass (owner, 23 November 2026).
 *
 * The agent on the owner's machine reads the client folders at ten and at
 * seven, and wakes every fifteen minutes for the phone photos. This is how an
 * afternoon's dropped stub is picked up without waiting for the evening: the
 * ask is a row, the agent sees it on its next wake, and the row records which
 * run answered it.
 *
 * It asks; it cannot make anything happen. If the machine is off, the row
 * waits - which is the honest thing for a screen to say, and better than a
 * button that claims to have done something.
 */
export type RunNowState = { error: string | null; ok: string | null };

export async function askForAPass(_prev: RunNowState, _formData: FormData): Promise<RunNowState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  // The same pair the document inbox admits: Admin, or a billing edit grant.
  // The row-level policy says the same thing; this is so the answer is a
  // sentence rather than a refusal somebody has to interpret.
  if (me.role !== "Admin" && !can(me, "billing", "edit")) {
    return { error: "Your role does not ask the agent for anything.", ok: null };
  }

  const supabase = await createClient();

  // One open ask at a time. A second press before the agent has woken would
  // make two rows that one pass answers, which reads as two passes in the
  // record and tells nobody anything.
  const { data: already } = await supabase
    .from("inbox_scan_requests")
    .select("id, asked_at, asked_by_name")
    .is("done_at", null)
    .order("asked_at")
    .limit(1)
    .maybeSingle();
  if (already) {
    return {
      error: null,
      ok: `Already asked, by ${already.asked_by_name || "somebody"}. The agent takes it on its next wake.`,
    };
  }

  const { error } = await supabase.from("inbox_scan_requests").insert({
    asked_by: me.id,
    asked_by_name: me.name,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/documents");
  return { error: null, ok: "Asked. The agent reads the folders on its next wake, within fifteen minutes." };
}
