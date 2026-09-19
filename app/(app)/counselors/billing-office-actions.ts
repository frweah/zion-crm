"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { can } from "@/lib/roles";

export type BillingOfficeState = { error: string | null; ok: string | null };

const ADDRESS = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/**
 * Admin and Billing keep the billing offices current - a new contact, a group
 * address that finally exists. The database refuses anybody without Billing to
 * edit (0099) and logs every change; the check here only saves the round trip.
 */
export async function updateBillingOffice(_prev: BillingOfficeState, formData: FormData): Promise<BillingOfficeState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  if (!can(me, "billing", "edit")) return { error: "Only those with Billing to edit change a billing office.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const billingEmail = str("billing_email");
  const contactEmail = str("contact_email");
  if (!ADDRESS.test(billingEmail)) return { error: "The billing address does not look like an email address.", ok: null };
  if (contactEmail && !ADDRESS.test(contactEmail)) {
    return { error: "The contact's address does not look like an email address.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase
    .from("billing_offices")
    .update({
      billing_email: billingEmail,
      has_group_address: formData.get("has_group_address") === "on",
      contact_name: str("contact_name"),
      contact_title: str("contact_title"),
      contact_email: contactEmail,
      notes: str("notes"),
    })
    .eq("id", str("id"));
  if (error) return { error: error.message, ok: null };

  revalidatePath("/counselors");
  revalidatePath("/billing");
  return { error: null, ok: `${str("name")} saved.` };
}

/** Which billing office a counselor office bills through, and where it is. */
export async function setOfficeBilling(_prev: BillingOfficeState, formData: FormData): Promise<BillingOfficeState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  if (!can(me, "billing", "edit")) return { error: "Only those with Billing to edit change where an office bills.", ok: null };

  const office = String(formData.get("office") ?? "");
  const supabase = await createClient();
  const { error } = await supabase
    .from("offices")
    .update({
      billing_office_id: String(formData.get("billing_office_id") ?? ""),
      address: String(formData.get("address") ?? "").trim(),
      note: String(formData.get("note") ?? "").trim(),
    })
    .eq("name", office);
  if (error) return { error: error.message, ok: null };

  revalidatePath("/counselors");
  revalidatePath("/billing");
  revalidatePath("/clients");
  return { error: null, ok: `${office} saved.` };
}
