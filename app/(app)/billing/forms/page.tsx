import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { FORM_TEMPLATES, templateById } from "@/lib/form-templates";
import { fmtStamp } from "@/lib/constants";
import { emailConfigured } from "@/lib/email";

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

  return (
    <>
      <h1 className="h1">Forms</h1>
      <p className="sub">
        The DWS-USOR forms, what is outstanding, and what has gone to counselors
      </p>

      {!emailConfigured() && (
        <div className="alert">
          Email is not set up yet, so forms can be filled in and signed but not sent. Add a Resend
          API key and verify zionvocrehab.com to turn sending on.
        </div>
      )}

      <div className="card" style={{ marginBottom: 14 }}>
        <h3>In progress</h3>
        {pending.length === 0 ? (
          <div className="empty">Nothing outstanding.</div>
        ) : (
          <table className="t">
            <thead>
              <tr>
                <th>Form</th>
                <th>Client</th>
                <th>Month</th>
                <th>Status</th>
                <th>Last touched</th>
              </tr>
            </thead>
            <tbody>
              {pending.map((f) => (
                <tr key={f.id} className="row">
                  <td>
                    <Link
                      href={`/clients/${f.client_id}/forms/${f.id}`}
                      style={{ color: "inherit", fontWeight: 600 }}
                    >
                      {templateById(f.template_id)?.usor ?? f.template_id}
                    </Link>
                  </td>
                  <td>{clientName.get(f.client_id) ?? "—"}</td>
                  <td>{f.month ?? "—"}</td>
                  <td>
                    <span className={"chip " + (f.status === "Completed" ? "gold" : "")}>
                      {f.status}
                    </span>
                  </td>
                  <td style={{ fontSize: 12, color: "var(--muted)" }}>
                    {f.status === "Draft"
                      ? `started ${fmtStamp(f.created_at)}`
                      : `signed ${fmtStamp(f.completed_at)} by ${f.completed_by_name}`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <h3>Sent to counselors</h3>
        {sent.length === 0 ? (
          <div className="empty">None sent yet.</div>
        ) : (
          <table className="t">
            <tbody>
              {sent.map((f) => (
                <tr key={f.id} className="row">
                  <td>
                    <Link
                      href={`/clients/${f.client_id}/forms/${f.id}`}
                      style={{ color: "inherit" }}
                    >
                      {templateById(f.template_id)?.usor ?? f.template_id}
                    </Link>
                  </td>
                  <td>{clientName.get(f.client_id) ?? "—"}</td>
                  <td style={{ fontSize: 12, color: "var(--muted)" }}>
                    {fmtStamp(f.sent_at)} → {f.sent_to}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card">
        <h3>The forms and when they are due</h3>
        <table className="t">
          <thead>
            <tr>
              <th>Form</th>
              <th>Applies to</th>
              <th>Required for billing</th>
            </tr>
          </thead>
          <tbody>
            {FORM_TEMPLATES.map((t) => (
              <tr key={t.id}>
                <td>
                  <b>{t.usor}</b>
                  <div style={{ fontSize: 12 }}>{t.name}</div>
                  <div style={{ fontSize: 11, color: "var(--muted)" }}>{t.due}</div>
                </td>
                <td style={{ fontSize: 12 }}>
                  {t.incoming
                    ? "Received from the counselor"
                    : t.services.length
                      ? t.services.join(", ")
                      : "—"}
                </td>
                <td>
                  {t.requiredForBilling ? (
                    <span className="chip warn">Yes{t.monthly ? " · monthly" : ""}</span>
                  ) : (
                    <span className="chip">No</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
