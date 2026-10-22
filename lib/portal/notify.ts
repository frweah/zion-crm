import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { deliverNotice } from "./deliver";
import { portalAddressToType } from "./address";

/**
 * Tell a client something is waiting in their portal, if the database says a
 * notice may go now.
 *
 * Called with the staff member's own session, after their message is saved.
 * The claim is recorded before anything is sent, so the hourly limit counts
 * attempts and two replies a second apart cannot both send. A notice that
 * fails is recorded as failed and the message itself still stands - the
 * client sees it the next time they sign in.
 */
export async function notifyPortal(
  supabase: SupabaseClient<Database>,
  conversationId: string,
): Promise<{ sent: boolean; channel: "Text" | "Email" | null }> {
  const { data, error } = await supabase.rpc("portal_claim_notice", { p_conversation: conversationId });
  if (error) {
    console.error(`[portal] a notice could not be claimed: ${error.message}`);
    return { sent: false, channel: null };
  }
  const row = (data ?? [])[0];
  if (!row?.notice_id || !row.destination) return { sent: false, channel: null };

  const channel = row.channel === "Text" ? "Text" : "Email";
  const sent = await deliverNotice({
    channel,
    destination: row.destination,
    name: row.name ?? "",
    where: portalAddressToType(),
  });
  await supabase.rpc("portal_note_notice", {
    p_notice: row.notice_id,
    p_sent: sent.ok,
    p_detail: sent.ok ? "" : sent.error,
  });
  if (!sent.ok) console.error(`[portal] a notice was not delivered by ${channel}: ${sent.error}`);
  return { sent: sent.ok, channel };
}
