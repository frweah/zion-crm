"use server";

import { today } from "@/lib/constants";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type ClientFormState = { error: string | null; ok: string | null };

const CAN_EDIT = ["Admin", "Job Search", "Reports"];

/**
 * Add a referral: the client, how to reach them, and the first authorization
 * if one came with it (owner, 3 November 2026, parts 2a and 2c).
 *
 * The record starts at Intake and an intake task is raised for Job Search
 * automatically. The stage history row is written by a database trigger, so it
 * happens however the client was created.
 *
 * Three things this now insists on, and the first two are database rules as
 * well as rules here, because a rule only in an action is a rule the next
 * screen can forget:
 *
 *   A phone number, or the tick that says there is not one and why (0314).
 *
 *   An answer about texting, which may be "nobody asked" - recorded as no
 *   event at all, because a row saying nothing happened is worse than the
 *   absence it describes.
 *
 *   And the authorization, entered through add_authorization rather than an
 *   insert of its own, so a referral typed here and one entered on Billing
 *   produce the same record and pass the same gates.
 */
export async function addClient(
  _prev: ClientFormState,
  formData: FormData,
): Promise<ClientFormState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT.includes(me.role)) {
    return { error: "Your role cannot add clients.", ok: null };
  }

  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { error: "A full name is required.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const orNull = (v: string) => (v === "" ? null : v);
  const num = (k: string) => {
    const v = Number(str(k).replace(/[$,\s]/g, ""));
    return Number.isFinite(v) && v !== 0 ? v : null;
  };

  // A phone number, or the reason there is not one. The database refuses the
  // insert either way; this says it in a sentence before the round trip.
  const noPhone = formData.get("no_phone") === "on";
  const phone = noPhone ? "" : str("phone");
  const whyNoPhone = noPhone ? str("no_phone_reason") : "";
  if (!noPhone && !phone) {
    return { error: 'Give a phone number, or tick "No phone" and say why.', ok: null };
  }
  if (noPhone && !whyNoPhone) {
    return { error: "Say why there is no phone number.", ok: null };
  }

  const texting = str("texting");
  if (phone && !["granted", "declined", "not_asked"].includes(texting)) {
    return { error: "Say whether they may be texted, or that nobody asked.", ok: null };
  }

  const withAuth = formData.get("with_authorization") === "on";
  const canBill = me.role === "Admin" || me.role === "Billing";
  if (withAuth && !canBill) {
    return { error: "Entering an authorization is Billing's, or an Admin's.", ok: null };
  }
  if (withAuth && !num("rate")) {
    return { error: "Give what the authorization is worth.", ok: null };
  }
  if (withAuth && str("rate_type") === "Hourly" && !num("total_hours")) {
    return { error: "Give the hours the authorization allows.", ok: null };
  }

  const supabase = await createClient();

  const { data: client, error } = await supabase
    .from("clients")
    .insert({
      name,
      phone,
      no_phone_reason: whyNoPhone,
      agency_id: str("agency_id"),
      funding_source: str("funding_source") || "Utah VR",
      counselor_id: orNull(str("counselor_id")),
      caseload: str("caseload"),
      unit: str("unit"),
      referring_office: str("referring_office"),
      assigned_staff_id: orNull(str("assigned_staff_id")),
      billing_staff_id: orNull(str("billing_staff_id")),
      stage: "Intake",
      status: "Active",
    })
    .select("id, name, assigned_staff_id")
    .single();

  if (error) return { error: error.message, ok: null };

  // Date of birth is restricted, so it lives in its own table under its own
  // policy. Whoever can add the client may not be allowed to store this.
  const dob = orNull(str("dob"));
  let dobWarning = "";
  if (dob) {
    const { error: dobError } = await supabase
      .from("client_private")
      .insert({ client_id: client.id, dob });
    if (dobError) {
      dobWarning =
        " The date of birth was not saved — that field is limited to Admin, Intake & Client Reports, or the assigned staff member.";
    }
  }

  /**
   * Texting, answered at the start rather than months later.
   *
   * "Not asked" writes nothing, which is exactly what it means. A failure
   * here does not undo the client: the record is the point, and consent can
   * be set on their own screen - so it is reported in the same sentence
   * rather than thrown.
   */
  let consentWarning = "";
  if (phone && texting !== "not_asked") {
    const { error: consentError } = await supabase.rpc("set_sms_consent", {
      p_client_id: client.id,
      p_state: texting === "granted" ? "Granted" : "Declined",
      p_method: "Intake form",
      p_note: texting === "granted" ? `Said yes when the record was made, ${today()}` : "",
    });
    if (consentError) consentWarning = ` Texting consent was not saved: ${consentError.message}`;
  }

  /**
   * And the authorization, through the same function Billing uses.
   *
   * Reported rather than thrown for the same reason: a referral whose
   * authorization was refused is still a referral, and the person typing it
   * needs to know which half landed.
   */
  let authWarning = "";
  if (withAuth) {
    const { error: authError } = await supabase.rpc("add_authorization", {
      p_client: client.id,
      p_number: str("number"),
      p_service_type: str("service_type"),
      p_rate_type: str("rate_type"),
      p_rate: num("rate"),
      p_total_hours: num("total_hours"),
      p_start: orNull(str("start_date")),
      p_end: orNull(str("end_date")),
      p_funding_source: str("funding_source") || "Utah VR",
    });
    authWarning = authError
      ? ` The authorization was not saved: ${authError.message}`
      : ` ${str("service_type")} is on the record.`;
  }

  // Automation: new client raises the intake task for Job Search.
  const { data: jobSearch } = await supabase
    .from("staff")
    .select("id")
    .eq("role", "Job Search")
    .eq("active", true).eq("is_system", false)
    .limit(1)
    .maybeSingle();

  await supabase.from("tasks").insert({
    client_id: client.id,
    assigned_staff_id: client.assigned_staff_id ?? jobSearch?.id ?? me.id,
    title: `Complete intake for ${client.name}`,
    due: today(),
    status: "Open",
    created_by: me.id,
    system_generated: true,
  });

  revalidatePath("/clients");
  revalidatePath("/tasks");

  return {
    error: null,
    ok: `${client.name} added at Intake, and the intake task was raised.${authWarning}${consentWarning}${dobWarning}`,
  };
}
