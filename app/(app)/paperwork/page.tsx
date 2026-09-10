import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";
import { ORG } from "@/lib/roles";
import { W8BenForm } from "./w8ben-form";
import { W9Form } from "./w9-form";
import { W4Form } from "./w4-form";
import { DeliveryConsent } from "./delivery-consent";
import { DownloadButton } from "./download-button";

export default async function PaperworkPage() {
  const me = await requireStaff();
  const supabase = await createClient();

  const [profileResult, employmentResult, submissionsResult, staffResult] =
    await Promise.all([
      supabase
        .from("contractor_profiles")
        .select(
          "tax_status, w8ben_received_on, w8ben_expires_on, w9_received_on, e_delivery_consent_on",
        )
        .eq("staff_id", me.id)
        .maybeSingle(),
      supabase
        .from("staff_employment")
        .select("employment_type")
        .eq("staff_id", me.id)
        .maybeSingle(),
      supabase
        .from("tax_form_submissions")
        .select("id, staff_id, form_type, status, signed_at, signer_name, tin_last4, created_at, pdf_path, pdf_sha256")
        .order("created_at", { ascending: false }),
      me.role === "Admin"
        ? supabase.from("staff").select("id, name").eq("active", true)
        : Promise.resolve({ data: [] }),
    ]);

  const profile = profileResult.data;
  const submissions = submissionsResult.data ?? [];
  const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));

  const mine = submissions.filter((s) => s.staff_id === me.id);

  // Which form this person owes follows from how they are engaged, and that can
  // change after they have signed. An employee gives a W-4; a contractor gives
  // a W-9 or a W-8BEN depending on whether they are a US person. Someone who
  // filed a W-8BEN and is later recorded as a US person owes a W-9, and the
  // signed W-8BEN must not be taken as that being settled — so what is on file
  // is matched against what is required, not merely against having signed
  // something.
  const required =
    employmentResult.data?.employment_type === "Employee"
      ? "W-4"
      : profile?.tax_status === "Foreign person"
        ? "W-8BEN"
        : profile?.tax_status === "US person"
          ? "W-9"
          : null;

  const signed = mine.find((s) => s.status === "Signed" && s.form_type === required);
  const form =
    required === "W-8BEN" ? (
      <W8BenForm defaultName={me.name} />
    ) : required === "W-4" ? (
      <W4Form defaultName={me.name} />
    ) : required === "W-9" ? (
      <W9Form defaultName={me.name} />
    ) : null;

  return (
    <>
      <h1 className="h1">Paperwork</h1>
      <p className="sub">Your tax form, completed and signed here rather than on paper.</p>

      {signed ? (
        <>
          <div className="card" style={{ marginBottom: 14 }}>
            <h3>{signed.form_type} on file</h3>
            <p className="sub" style={{ marginTop: 0, marginBottom: 0 }}>
              Signed by {signed.signer_name} on {fmtStamp(signed.signed_at)}
              {signed.tin_last4 && ` · tax number ending ${signed.tin_last4}`}
              {signed.form_type === "W-8BEN" &&
                profile?.w8ben_expires_on &&
                ` · valid to ${profile.w8ben_expires_on}`}
            </p>
            <p className="lock" style={{ marginTop: 10, marginBottom: 0 }}>
              The completed form is held securely and can be opened by the administrator only. If
              anything on it changes — your address, your country, your tax number — complete a new
              one and it will replace this.
            </p>
          </div>
          <details className="card" style={{ marginBottom: 14 }}>
            <summary style={{ cursor: "pointer", fontWeight: 600 }}>
              Something has changed — complete a new {signed.form_type}
            </summary>
            <p className="lock">
              Signing a new one replaces the form above. The old one stays in your history, marked
              superseded, because a form that was true when it was signed is still a record of what
              was certified then.
            </p>
            {form}
          </details>
        </>
      ) : (
        (form ?? (
          <div className="card">
            <h3>Nothing to complete yet</h3>
            <p className="sub" style={{ margin: 0 }}>
              The administrator sets how you are engaged and, for a contractor, whether you are a
              US person. Once that is set, the right form — a W-4, a W-9 or a W-8BEN — appears
              here.
            </p>
          </div>
        ))
      )}

      {!signed && required && mine.some((s) => s.status === "Signed") && (
        <div className="alert" style={{ marginTop: 14 }}>
          How you are engaged has changed since you last signed, so a {required} is now the form we
          need. The form you signed before stays in your history.
        </div>
      )}

      {/* Only contractors get a 1099, so only they are asked how it should reach
          them. An employee gets a W-2, which is a different conversation. */}
      {required !== "W-4" && profile && (
        <DeliveryConsent consentedOn={profile.e_delivery_consent_on} />
      )}

      {mine.length > 0 && (
        <div className="card" style={{ marginTop: 14, padding: 0 }}>
          <h3 style={{ padding: "16px 16px 0" }}>Your history</h3>
          <table className="t">
            <tbody>
              {mine.map((s) => (
                <tr key={s.id}>
                  <td>{s.form_type}</td>
                  <td>
                    <span
                      className={
                        "chip " + (s.status === "Signed" ? "ok" : s.status === "Draft" ? "" : "warn")
                      }
                    >
                      {s.status}
                    </span>
                  </td>
                  <td style={{ fontSize: 12, color: "var(--muted)" }}>
                    {s.signed_at ? `signed ${fmtStamp(s.signed_at)}` : `started ${fmtStamp(s.created_at)}`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {me.role === "Admin" && (
        <div className="card" style={{ marginTop: 14, padding: 0 }}>
          <h3 style={{ padding: "16px 16px 0" }}>Everyone&apos;s paperwork</h3>
          <table className="t">
            <thead>
              <tr>
                <th>Who</th>
                <th>Form</th>
                <th>Status</th>
                <th>Signed</th>
                <th>PDF</th>
              </tr>
            </thead>
            <tbody>
              {submissions.length === 0 && (
                <tr>
                  <td colSpan={5} className="empty">
                    Nothing filed yet.
                  </td>
                </tr>
              )}
              {submissions.map((s) => (
                <tr key={s.id}>
                  <td>{staffName.get(s.staff_id) ?? "—"}</td>
                  <td>{s.form_type}</td>
                  <td>
                    <span className={"chip " + (s.status === "Signed" ? "ok" : "")}>{s.status}</span>
                  </td>
                  <td style={{ fontSize: 12, color: "var(--muted)" }}>
                    {s.signed_at ? `${s.signer_name} · ${fmtStamp(s.signed_at)}` : "—"}
                    {s.pdf_sha256 && (
                      <div title="SHA-256 of the filed PDF">{s.pdf_sha256.slice(0, 12)}…</div>
                    )}
                  </td>
                  <td>
                    <DownloadButton pdfPath={s.pdf_path ?? ""} submissionId={s.id} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="lock" style={{ padding: "0 16px 16px" }}>
            The completed PDFs are in each person&apos;s file, readable by you only.
          </p>
        </div>
      )}
    </>
  );
}
