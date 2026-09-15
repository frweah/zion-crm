import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { FORM_TEMPLATES, templateById } from "@/lib/form-templates";
import { fmtStamp } from "@/lib/constants";
import { emailConfigured } from "@/lib/email";
import { PageHead } from "../../page-head";
import { DataTable, type DataRow } from "../../data-table";

export default async function FormsLibraryPage() {
  await requireStaff();
  const supabase = await createClient();

  const [formsResult, clientsResult] = await Promise.all([
    supabase
      .from("forms")
      .select(
        "id, template_id, client_id, status, month, created_at, completed_at, completed_by_name, sent_at, sent_to",
      )
      .order("created_at", { ascending: false }),
    supabase.from("clients").select("id, name"),
  ]);

  const forms = formsResult.data ?? [];
  const clientName = new Map((clientsResult.data ?? []).map((c) => [c.id, c.name]));

  const pending = forms.filter((f) => f.status !== "Sent");
  const sent = forms.filter((f) => f.status === "Sent");

  const formName = (templateId: string) => templateById(templateId)?.usor ?? templateId;

  const pendingRows: DataRow[] = pending.map((f) => {
    const client = clientName.get(f.client_id) ?? "—";
    const touched =
      f.status === "Draft"
        ? `started ${fmtStamp(f.created_at)}`
        : `signed ${fmtStamp(f.completed_at)} by ${f.completed_by_name}`;
    return {
      key: f.id,
      cells: {
        form: (
          <Link href={`/clients/${f.client_id}/forms/${f.id}`} style={{ color: "inherit", fontWeight: 600 }}>
            {formName(f.template_id)}
          </Link>
        ),
        client,
        month: f.month ?? "—",
        status: <span className={"chip " + (f.status === "Completed" ? "gold" : "")}>{f.status}</span>,
        touched: <span style={{ fontSize: 12, color: "var(--muted)" }}>{touched}</span>,
      },
      sort: {
        form: formName(f.template_id),
        status: f.status,
        touched: f.status === "Draft" ? f.created_at : f.completed_at,
      },
      text: [formName(f.template_id), client, f.month, f.status, touched].filter(Boolean).join(" "),
    };
  });

  const sentRows: DataRow[] = sent.map((f) => {
    const client = clientName.get(f.client_id) ?? "—";
    return {
      key: f.id,
      cells: {
        form: (
          <Link href={`/clients/${f.client_id}/forms/${f.id}`} style={{ color: "inherit" }}>
            {formName(f.template_id)}
          </Link>
        ),
        client,
        sent: (
          <span style={{ fontSize: 12, color: "var(--muted)" }}>
            {fmtStamp(f.sent_at)} → {f.sent_to}
          </span>
        ),
      },
      sort: { form: formName(f.template_id), sent: f.sent_at },
      text: [formName(f.template_id), client, f.sent_to].filter(Boolean).join(" "),
    };
  });

  const templateRows: DataRow[] = FORM_TEMPLATES.map((t) => {
    const billing = t.requiredForBilling ? `Yes${t.monthly ? " · monthly" : ""}` : "No";
    return {
      key: t.id,
      cells: {
        form: (
          <>
            <b>{t.usor}</b>
            <div style={{ fontSize: 12 }}>{t.name}</div>
            <div style={{ fontSize: 11, color: "var(--muted)" }}>{t.due}</div>
          </>
        ),
        applies: t.incoming
          ? "Received from the counselor"
          : t.services.length
            ? t.services.join(", ")
            : "—",
        billing: <span className={"chip " + (t.requiredForBilling ? "warn" : "")}>{billing}</span>,
      },
      sort: { form: t.usor, billing },
      text: [t.usor, t.name, t.due, t.services.join(" "), billing].join(" "),
    };
  });

  return (
    <>
      <PageHead
        title="Forms"
        context="The DWS-USOR forms, what is outstanding, and what has gone to counselors"
      />

      {!emailConfigured() && (
        <div className="alert">
          Email is not set up yet, so forms can be filled in and signed but not sent. Add a Resend
          API key and verify zionvocrehab.com to turn sending on.
        </div>
      )}

      <section style={{ marginBottom: 24 }}>
        <h2 className="h2" style={{ marginBottom: 8 }}>
          In progress
        </h2>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="forms"
            columns={[
              { key: "form", label: "Form" },
              { key: "client", label: "Client" },
              { key: "month", label: "Month" },
              { key: "status", label: "Status" },
              { key: "touched", label: "Last touched" },
            ]}
            rows={pendingRows}
            empty="Nothing outstanding: no form is in progress."
          />
        </div>
      </section>

      <section style={{ marginBottom: 24 }}>
        <h2 className="h2" style={{ marginBottom: 8 }}>
          Sent to counselors
        </h2>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="forms"
            columns={[
              { key: "form", label: "Form" },
              { key: "client", label: "Client" },
              { key: "sent", label: "Sent" },
            ]}
            rows={sentRows}
            empty="No form has been sent to a counselor yet."
          />
        </div>
      </section>

      <section>
        <h2 className="h2" style={{ marginBottom: 8 }}>
          The forms and when they are due
        </h2>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="forms"
            columns={[
              { key: "form", label: "Form" },
              { key: "applies", label: "Applies to" },
              { key: "billing", label: "Required for billing" },
            ]}
            rows={templateRows}
            empty="No form templates are defined."
          />
        </div>
      </section>
    </>
  );
}
