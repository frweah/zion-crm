import { notFound } from "next/navigation";
import { RecordHeader } from "../../../../record-header";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { templateById } from "@/lib/form-templates";
import { formToText, type FormContext } from "@/lib/form-text";
import { FormRenderer } from "./form-renderer";
import { FormReadiness, type Blocker } from "./readiness";
import { today } from "@/lib/constants";
import { recipientsFor, type BillingOffice } from "@/lib/billing-offices";

export default async function FormPage({
  params,
}: {
  params: Promise<{ id: string; formId: string }>;
}) {
  const { id, formId } = await params;
  await requireStaff();
  const supabase = await createClient();

  // A restricted form simply is not returned by RLS, so this covers both
  // "no such form" and "not yours to open".
  const { data: form } = await supabase
    .from("forms")
    .select(
      "id, template_id, client_id, auth_id, month, status, data, completed_by_name, completed_at, sent_to, updated_at",
    )
    .eq("id", formId)
    .eq("client_id", id)
    .maybeSingle();

  if (!form) notFound();

  const template = templateById(form.template_id);
  if (!template) notFound();

  const { data: client } = await supabase
    .from("clients")
    .select("id, name, client_no, agency_id, counselor_id")
    .eq("id", id)
    .maybeSingle();

  const [{ data: counselor }, { data: auth }] = await Promise.all([
    client?.counselor_id
      ? supabase
          .from("counselors")
          .select("name, email")
          .eq("id", client.counselor_id)
          .maybeSingle()
      : Promise.resolve({ data: null }),
    form.auth_id
      ? supabase
          .from("authorizations")
          .select("number, service_type")
          .eq("id", form.auth_id)
          .maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  // Where it goes by default: the client's billing office, copying the counselor.
  const { data: billingRow } = await supabase
    .from("client_billing_office")
    .select("billing_office_id")
    .eq("client_id", id)
    .maybeSingle();
  const { data: billingOffice } = billingRow?.billing_office_id
    ? await supabase
        .from("billing_offices")
        .select("id, name, billing_email, has_group_address, contact_name, contact_title, contact_email, notes")
        .eq("id", billingRow.billing_office_id)
        .maybeSingle()
    : { data: null };
  const recipients = recipientsFor((billingOffice as BillingOffice | null) ?? null, counselor ?? null);

  const ctx: FormContext = {
    clientName: client?.name ?? "",
    clientNo: client?.client_no ?? null,
    agencyId: client?.agency_id ?? "",
    counselorName: counselor?.name ?? "",
    authNumber: auth?.number ?? "",
    authServiceType: auth?.service_type ?? "",
    completedBy: form.completed_by_name,
    completedAt: form.completed_at,
  };

  const preview = formToText(form.template_id, form.data as Record<string, unknown>, ctx);

  // ── what stands between this form and the counselor (punch list #3) ──
  const draft = form.status === "Draft";
  const blockers: Blocker[] = [];
  let authChoices: { id: string; label: string }[] = [];
  let suggested: string | null = null;
  if (form.status !== "Sent") {
    if (!form.auth_id) {
      const { data: auths } = await supabase
        .from("authorizations")
        .select("id, number, service_type, status")
        .eq("client_id", id)
        .order("start_date", { ascending: false, nullsFirst: false });
      const fits = (a: { service_type: string }) => template.services?.includes(a.service_type) ?? false;
      const list = auths ?? [];
      authChoices = [...list.filter(fits), ...list.filter((a) => !fits(a))].map((a) => ({
        id: a.id,
        label: `${a.number} · ${a.service_type} · ${a.status}${fits(a) ? "" : " (not a service this form is for)"}`,
      }));
      const matching = list.filter(fits);
      suggested = matching.length === 1 ? matching[0].id : null;
      blockers.push({
        tone: template.requiredForBilling ? "bad" : "warn",
        text: template.requiredForBilling
          ? "No authorization is attached, so this form cannot count towards any invoice."
          : "No authorization is attached.",
      });
    } else if (auth?.number?.startsWith("(workbook)")) {
      blockers.push({
        tone: "bad",
        text: `It is on ${auth.number}, a workbook placeholder with no USOR number, so it cannot be sent. Put the USOR number on it first.`,
        href: "/billing?tab=authorizations",
        linkText: "Billing → Authorizations",
      });
    }
    const data = (form.data ?? {}) as Record<string, unknown>;
    if (form.template_id === "usor95" && !(Array.isArray(data.rows) && data.rows.length > 0)) {
      blockers.push({
        tone: "warn",
        text: `No coaching is on the daily log for ${form.month ?? "this month"}. Log the visits, then fill it again from the record.`,
      });
    }
    if (template.monthly && form.month && form.month >= today().slice(0, 7)) {
      blockers.push({ tone: "warn", text: `${form.month} is not over yet - a monthly form reports a finished month.` });
    }
    if (!recipients.to) {
      blockers.push({ tone: "warn", text: "Nobody to send it to: no billing office and no counselor email on file for this client." });
    }
  }

  return (
    <>
      {/*
        A form's state is always worth saying and carries its colour, so it
        goes on the standing line as a toned chip rather than as the header's
        plain status chip.
      */}
      <RecordHeader
        back={{ href: `/clients/${id}?tab=documents`, label: `${client?.name ?? "Client"} · Documents` }}
        title={template.usor}
        identity={[template.name, client?.name]}
        standing={
          <span
            className={
              "chip " + (form.status === "Sent" ? "ok" : form.status === "Completed" ? "gold" : "")
            }
          >
            {form.status}
          </span>
        }
      />

      <div className="alert" style={{ marginTop: 14 }}>
        <b>When this is due:</b> {template.due}
        {form.month && ` · reporting month ${form.month}`}
        {auth?.number && ` · authorization ${auth.number}`}
      </div>

      <FormReadiness
        formId={form.id}
        clientId={id}
        blockers={blockers}
        draft={draft}
        authChoices={authChoices}
        suggested={suggested}
        canRefill={["usor60", "usor92", "usor93", "usor95", "usor96", "usor148", "wsa"].includes(form.template_id)}
      />

      <FormRenderer
        key={form.updated_at}
        template={template}
        formId={form.id}
        clientId={id}
        initialData={(form.data ?? {}) as Record<string, unknown>}
        status={form.status}
        locked={form.status !== "Draft"}
        signedBy={form.completed_by_name}
        signedAt={form.completed_at}
        sentTo={form.sent_to}
        recipients={recipients}
        counselorName={counselor?.name ?? ""}
        preview={preview}
      />
    </>
  );
}
