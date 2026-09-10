"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type RequestState = { error: string | null; ok: string | null };

/**
 * Write down that somebody asked for a client's record.
 *
 * Logged when it arrives, not when it is answered. "We received a request and
 * did nothing about it for five weeks" is a fact somebody may one day need,
 * and it is precisely the fact that disappears when the only record of a
 * request is the bundle it eventually produced.
 */
export async function logRequest(
  _prev: RequestState,
  formData: FormData,
): Promise<RequestState> {
  const me = await getCurrentStaff();
  if (!me || me.role !== "Admin") {
    return { error: "Only Admin handles a records request.", ok: null };
  }

  const clientId = String(formData.get("client_id") ?? "").trim();
  const requestedBy = String(formData.get("requested_by") ?? "").trim();
  const requestedOn = String(formData.get("requested_on") ?? "").trim();
  const note = String(formData.get("note") ?? "").trim();

  if (!clientId) return { error: "Whose record was asked for?", ok: null };
  if (!requestedBy) {
    return { error: "Who asked? The client, an attorney, USOR — say which.", ok: null };
  }

  const supabase = await createClient();

  const { data: client } = await supabase
    .from("clients")
    .select("name")
    .eq("id", clientId)
    .maybeSingle();

  const { error } = await supabase.from("records_requests").insert({
    client_id: clientId,
    client_name: client?.name ?? "",
    requested_by: requestedBy,
    ...(requestedOn ? { requested_on: requestedOn } : {}),
    note,
    created_by: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/records-request");
  return { error: null, ok: "Logged. Open it to gather the record." };
}
