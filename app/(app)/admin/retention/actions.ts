"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type RetentionState = { error: string | null; ok: string | null };

/**
 * Change a period, or confirm it.
 *
 * Confirming is the act that gives a policy teeth: until somebody has checked
 * the number against the rule it cites, nothing under it is ever reported as
 * due. So confirming is deliberately separate from editing, and editing a
 * confirmed policy un-confirms it — a period that changed is a period nobody
 * has checked, whatever was checked before.
 */
export async function savePolicy(
  _prev: RetentionState,
  formData: FormData,
): Promise<RetentionState> {
  const me = await getCurrentStaff();
  if (!me || me.role !== "Admin") {
    return { error: "Only Admin sets the retention schedule.", ok: null };
  }

  const key = String(formData.get("key") ?? "");
  const years = Number(formData.get("keep_years") ?? "");
  const authority = String(formData.get("authority") ?? "").trim();

  if (!Number.isFinite(years) || years <= 0) {
    return { error: "How many years? It has to be more than none.", ok: null };
  }
  if (years > 100) {
    return { error: "A hundred years is not a retention period.", ok: null };
  }

  const supabase = await createClient();
  const { data: current } = await supabase
    .from("retention_policies")
    .select("keep_years, authority, confirmed")
    .eq("key", key)
    .maybeSingle();

  if (!current) return { error: "There is no such policy.", ok: null };

  const changed = Number(current.keep_years) !== years || current.authority !== authority;

  const { error } = await supabase
    .from("retention_policies")
    .update({
      keep_years: years,
      authority,
      updated_by: me.id,
      // A changed period has not been checked by anybody, including the
      // person who just changed it.
      ...(changed && current.confirmed
        ? { confirmed: false, confirmed_by: null, confirmed_at: null }
        : {}),
    })
    .eq("key", key);

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/retention");
  return {
    error: null,
    ok:
      changed && current.confirmed
        ? "Saved. Because the period changed, it now needs confirming again."
        : "Saved.",
  };
}

/**
 * Say that this period has been checked against the rule it cites.
 *
 * The one act in 10.3 that lets a record become due for destruction, so it is
 * its own button with its own words rather than a checkbox on a form somebody
 * is already filling in.
 */
export async function confirmPolicy(
  _prev: RetentionState,
  formData: FormData,
): Promise<RetentionState> {
  const me = await getCurrentStaff();
  if (!me || me.role !== "Admin") {
    return { error: "Only Admin confirms a retention period.", ok: null };
  }

  const key = String(formData.get("key") ?? "");
  const confirming = formData.get("confirmed") !== "yes";

  const supabase = await createClient();
  const { error } = await supabase
    .from("retention_policies")
    .update(
      confirming
        ? { confirmed: true, confirmed_by: me.id, confirmed_at: new Date().toISOString() }
        : { confirmed: false, confirmed_by: null, confirmed_at: null },
    )
    .eq("key", key);

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/retention");
  return {
    error: null,
    ok: confirming
      ? "Confirmed. Records under this policy can now reach the end of their period."
      : "No longer confirmed. Nothing under this policy will be reported as due.",
  };
}

/**
 * Put a client's record beyond the reach of the schedule.
 *
 * A dispute, an audit, a records request, an open complaint. While it stands,
 * that record is not due for anything and cannot be recorded as destroyed —
 * the database refuses, not the screen.
 */
export async function placeHold(
  _prev: RetentionState,
  formData: FormData,
): Promise<RetentionState> {
  const me = await getCurrentStaff();
  if (!me || me.role !== "Admin") {
    return { error: "Only Admin places a legal hold.", ok: null };
  }

  const clientId = String(formData.get("client_id") ?? "").trim();
  const reason = String(formData.get("reason") ?? "").trim();

  if (!clientId) return { error: "Which client's record?", ok: null };
  if (!reason) {
    return { error: "Say why. A hold nobody can explain is a hold nobody will lift.", ok: null };
  }

  const supabase = await createClient();

  const { data: standing } = await supabase
    .from("legal_holds")
    .select("id")
    .eq("client_id", clientId)
    .is("lifted_at", null)
    .maybeSingle();

  if (standing) return { error: "That record is already under hold.", ok: null };

  const { error } = await supabase.from("legal_holds").insert({
    client_id: clientId,
    reason,
    placed_by: me.id,
    placed_by_name: me.name,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/retention");
  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: "Held. Nothing on that record can be destroyed until it is lifted." };
}

/** End a hold. Lifted, never deleted — that it was placed is part of the record. */
export async function liftHold(
  _prev: RetentionState,
  formData: FormData,
): Promise<RetentionState> {
  const me = await getCurrentStaff();
  if (!me || me.role !== "Admin") {
    return { error: "Only Admin lifts a legal hold.", ok: null };
  }

  const id = String(formData.get("hold_id") ?? "");
  const reason = String(formData.get("lifted_reason") ?? "").trim();
  if (!reason) return { error: "Say why it is being lifted.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("legal_holds")
    .update({
      lifted_at: new Date().toISOString(),
      lifted_by: me.id,
      lifted_by_name: me.name,
      lifted_reason: reason,
    })
    .eq("id", id)
    .is("lifted_at", null);

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/retention");
  return { error: null, ok: "Lifted. The schedule applies to that record again." };
}

/**
 * Record what was decided about a record that has passed its period.
 *
 * The refusals live in the database — a destruction under hold, or before the
 * period has passed, is refused there rather than here, so a second screen
 * could not get it wrong.
 *
 * Note what this does not do: it does not delete anything. It records that a
 * person decided and acted.
 */
export async function recordDisposition(
  _prev: RetentionState,
  formData: FormData,
): Promise<RetentionState> {
  const me = await getCurrentStaff();
  if (!me || me.role !== "Admin") {
    return { error: "Only Admin records a retention decision.", ok: null };
  }

  const clientId = String(formData.get("client_id") ?? "");
  const action = String(formData.get("action") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();

  if (!reason) return { error: "Say what was done and why.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("record_disposition", {
    p_client: clientId,
    p_action: action,
    p_reason: reason,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/retention");
  return { error: null, ok: "Recorded." };
}
