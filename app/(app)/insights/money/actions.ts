"use server";

import { revalidatePath } from "next/cache";
import { can } from "@/lib/roles";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type FollowupState = { error: string | null; ok: string | null };

/**
 * Who owns getting an authorization invoiced, what happens next, and by when
 * (punch list #5). Written under the authorization's own write rule; the
 * database stamps when and by whom (0114).
 */
export async function setFollowup(_prev: FollowupState, formData: FormData): Promise<FollowupState> {
  const me = await getCurrentStaff();
  if (!me || !can(me, "billing", "edit")) {
    return { error: "Only Admin and Billing set who is moving an authorization.", ok: null };
  }
  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const authId = str("auth_id");
  if (!authId) return { error: "No authorization.", ok: null };

  const owner = str("owner") || null;
  const action = str("action");
  const due = str("due") || null;
  if (owner && !action) return { error: "Say what the next action is, as well as who owns it.", ok: null };
  if (action.length > 500) return { error: "Keep the next action under 500 characters.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("authorizations")
    .update({ followup_owner: owner, followup_action: action, followup_due: due })
    .eq("id", authId)
    .select("id");
  if (error) return { error: error.message, ok: null };
  if (!data?.length) return { error: "That authorization could not be changed.", ok: null };

  revalidatePath("/insights/money");
  return { error: null, ok: "Saved." };
}
