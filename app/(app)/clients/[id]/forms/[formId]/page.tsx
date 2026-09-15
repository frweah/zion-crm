import { notFound } from "next/navigation";
import { RecordHeader } from "../../../../record-header";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { templateById } from "@/lib/form-templates";
import { formToText, type FormContext } from "@/lib/form-text";
import { FormRenderer } from "./form-renderer";

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
      "id, template_id, client_id, auth_id, month, status, data, completed_by_name, completed_at, sent_to",
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

      <FormRenderer
        template={template}
        formId={form.id}
        clientId={id}
        initialData={(form.data ?? {}) as Record<string, unknown>}
        status={form.status}
        locked={form.status !== "Draft"}
        signedBy={form.completed_by_name}
        signedAt={form.completed_at}
        sentTo={form.sent_to}
        counselorEmail={counselor?.email ?? ""}
        counselorName={counselor?.name ?? ""}
        preview={preview}
      />
    </>
  );
}
