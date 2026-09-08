"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { ownAccess } from "@/lib/sync-callers";
import { ensureFreshToken, listMessagesSince } from "@/lib/graph";

export type SharedState = { error: string | null; ok: string | null };

/**
 * Records a shared mailbox for the sweep to read.
 *
 * The address is checked against Graph before it is saved. Saving an address
 * that cannot actually be read would produce a mailbox that silently logs
 * nothing, and the failure would show up weeks later as "why is there no
 * counselor mail" rather than now as "Exchange has not given you access to
 * that mailbox".
 */
export async function addSharedMailbox(
  _prev: SharedState,
  formData: FormData,
): Promise<SharedState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") {
    return { error: "Only Admin can set up the shared mailbox.", ok: null };
  }

  const address = String(formData.get("address") ?? "").trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(address)) {
    return { error: "That does not look like an email address.", ok: null };
  }

  const supabase = await createClient();
  const { tokens } = ownAccess(supabase, me.id);
  const bundle = await tokens.read();

  if (!bundle) {
    return {
      error: "Connect your own Outlook account first — the shared mailbox is read using your access to it.",
      ok: null,
    };
  }

  try {
    const token = await ensureFreshToken(bundle, tokens.write);
    // One message is enough to prove it can be read at all.
    await listMessagesSince(token, new Date(Date.now() - 86400000), 1, address);
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown error";
    return {
      error: message.includes("403")
        ? `Microsoft refused: your account does not have access to ${address}, or the Mail.Read.Shared permission has not been granted and consented. Reconnect with "Connect the shared mailbox" after an Exchange administrator has given you access.`
        : `Could not read ${address}: ${message}`,
      ok: null,
    };
  }

  const { error } = await supabase.from("shared_mailboxes").upsert(
    {
      address,
      label: String(formData.get("label") ?? "").trim(),
      connected_by: me.id,
      active: true,
      last_error: "",
    },
    { onConflict: "address" },
  );

  if (error) return { error: error.message, ok: null };

  revalidatePath("/dashboard");
  return { error: null, ok: `${address} will be swept from the next sync.` };
}

/** Stops reading a shared mailbox. What it already logged stays. */
export async function removeSharedMailbox(
  _prev: SharedState,
  formData: FormData,
): Promise<SharedState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") {
    return { error: "Only Admin can change this.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase
    .from("shared_mailboxes")
    .delete()
    .eq("address", String(formData.get("address") ?? ""));

  if (error) return { error: error.message, ok: null };

  revalidatePath("/dashboard");
  return {
    error: null,
    ok: "Stopped. What it has already logged stays on the records it was logged against.",
  };
}
