"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { syncStaffMember } from "@/lib/sync";
import { ownAccess } from "@/lib/sync-callers";

export type SyncState = { error: string | null; ok: string | null };

/**
 * Sync now, for the person asking.
 *
 * There is no staff id parameter, deliberately. The only mailbox reachable
 * from here is the caller's own, because that is the only one the database
 * functions behind it will open.
 */
export async function syncNow(_prev: SyncState, _formData: FormData): Promise<SyncState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { tokens, writeMail } = ownAccess(supabase, me.id);

  const result = await syncStaffMember(supabase, me.id, tokens, writeMail);

  revalidatePath("/dashboard");
  revalidatePath("/clients");

  if (result.errors.length > 0) {
    return { error: result.errors.join("; "), ok: null };
  }

  const parts: string[] = [];
  if (result.mailLogged > 0) {
    parts.push(`${result.mailLogged} message${result.mailLogged === 1 ? "" : "s"} logged`);
  }
  if (result.eventsPulled > 0) {
    parts.push(`${result.eventsPulled} appointment${result.eventsPulled === 1 ? "" : "s"} brought in`);
  }

  return {
    error: null,
    ok:
      parts.length > 0
        ? `${parts.join(", ")}. ${result.skippedNoMatch} message${result.skippedNoMatch === 1 ? "" : "s"} matched nobody and were left alone.`
        : `Nothing new. ${result.skippedNoMatch} message${result.skippedNoMatch === 1 ? "" : "s"} matched nobody and were left alone.`,
  };
}
