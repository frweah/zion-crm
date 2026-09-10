"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type CredentialState = { error: string | null; ok: string | null };

/**
 * Record a credential somebody holds.
 *
 * A renewal is a new row, never an edit. A CPR card that ran out in March and
 * was renewed in April is two facts, and "were they covered on the day of
 * that incident" needs both — so nothing here updates what is already down.
 *
 * Verified is stamped by whoever records it, because recording one is the act
 * of having seen it. If somebody records a credential they have not seen,
 * that is a different problem and not one a form can solve.
 */
export async function recordCredential(
  _prev: CredentialState,
  formData: FormData,
): Promise<CredentialState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") {
    return { error: "Only Admin records credentials — it is a check somebody performed.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const staffId = str("staff_id");
  const typeKey = str("type_key");
  const issued = str("issued_on");
  const expires = str("expires_on");

  if (!staffId || !typeKey) return { error: "Which credential, and whose?", ok: null };
  if (expires && issued && expires < issued) {
    return { error: "That expires before it was issued — one of the two dates is wrong.", ok: null };
  }

  const supabase = await createClient();

  // What the type says about itself decides whether an expiry is needed. A
  // CPR card with no date is the one that quietly never expires.
  const { data: type } = await supabase
    .from("credential_types")
    .select("label, expires, kind")
    .eq("key", typeKey)
    .maybeSingle();

  if (!type) return { error: "Unknown credential.", ok: null };
  if (type.kind === "hours") {
    return { error: "Continuing education is logged as hours, not as a certificate.", ok: null };
  }
  if (type.expires && !expires) {
    return { error: `A ${type.label} expires — put the date on it, or it will never come up for renewal.`, ok: null };
  }

  const { error } = await supabase.from("staff_credentials").insert({
    staff_id: staffId,
    type_key: typeKey,
    reference: str("reference"),
    issued_on: issued || null,
    expires_on: expires || null,
    note: str("note"),
    verified_by: me.id,
    verified_at: new Date().toISOString(),
    created_by: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/staff");
  revalidatePath("/paperwork");
  return { error: null, ok: `${type.label} recorded.` };
}

/**
 * Whether somebody carries clients in a vehicle.
 *
 * A property of the person rather than their role: a job coach who does not
 * drive should not be chased for insurance, and an administrator who does
 * should be.
 */
export async function setTransportsClients(
  _prev: CredentialState,
  formData: FormData,
): Promise<CredentialState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Admin only.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "");
  const transports = formData.get("transports") === "yes";

  const supabase = await createClient();
  const { error } = await supabase
    .from("staff_employment")
    .upsert(
      { staff_id: staffId, transports_clients: transports },
      { onConflict: "staff_id" },
    );

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/staff");
  return {
    error: null,
    ok: transports
      ? "Recorded. A licence and insurance are now required of them."
      : "Recorded. A licence and insurance are no longer required of them.",
  };
}

/**
 * Log continuing-education hours.
 *
 * People log their own — they are the ones who sat through it. Admin can log
 * for somebody else, which is what happens when a certificate arrives by
 * email addressed to the practice.
 */
export async function logCeHours(
  _prev: CredentialState,
  formData: FormData,
): Promise<CredentialState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const staffId = str("staff_id") || me.id;
  const hours = Number(str("hours"));
  const topic = str("topic");
  const onDate = str("on_date");

  if (staffId !== me.id && me.role !== "Admin") {
    return { error: "You can log your own hours; Admin logs anybody's.", ok: null };
  }
  if (!onDate) return { error: "When was it?", ok: null };
  if (!(hours > 0)) return { error: "How many hours?", ok: null };
  if (!topic) return { error: "What was it about? A total with no topic proves nothing.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("ce_entries").insert({
    staff_id: staffId,
    on_date: onDate,
    hours,
    topic,
    provider: str("provider"),
    created_by: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/paperwork");
  revalidatePath("/admin/staff");
  return { error: null, ok: `${hours} hours logged.` };
}
