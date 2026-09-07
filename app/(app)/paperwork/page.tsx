import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";
import { W8BenForm } from "./w8ben-form";
import { DownloadButton } from "./download-button";

export default async function PaperworkPage() {
  const me = await requireStaff();
  const supabase = await createClient();

  const [profileResult, submissionsResult, staffResult] = await Promise.all([
    supabase
      .from("contractor_profiles")
      .select("tax_status, w8ben_received_on, w8ben_expires_on, w9_received_on")
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
  const signed = mine.find((s) => s.status === "Signed");
  const isForeign = profile?.tax_status === "Foreign person";

  return (
    <>
      <h1 className="h1">Paperwork</h1>
      <p className="sub">Your tax form, completed and signed here rather than on paper.</p>

      {signed ? (
        <div className="card" style={{ marginBottom: 14 }}>
          <h3>{signed.form_type} on file</h3>
          <p className="sub" style={{ marginTop: 0, marginBottom: 0 }}>
            Signed by {signed.signer_name} on {fmtStamp(signed.signed_at)}
            {signed.tin_last4 && ` · tax number ending ${signed.tin_last4}`}
            {profile?.w8ben_expires_on && ` · valid to ${profile.w8ben_expires_on}`}
          </p>
          <p className="lock" style={{ marginTop: 10, marginBottom: 0 }}>
            The completed form is held securely and can be opened by the administrator only. If
            anything on it changes — your address, your country, your tax number — complete a new
            one and it will replace this.
          </p>
        </div>
      ) : isForeign ? (
        <W8BenForm defaultName={me.name} />
      ) : profile?.tax_status === "US person" ? (
        <div className="card">
          <h3>Form W-9</h3>
          <p className="sub" style={{ margin: 0 }}>
            The in-app W-9 is being built next. Until then the administrator will ask you for one
            directly.
          </p>
        </div>
      ) : (
        <div className="card">
          <h3>Nothing to complete yet</h3>
          <p className="sub" style={{ margin: 0 }}>
            The administrator sets whether you file a W-8BEN or a W-9. Once that is set, the right
            form appears here.
          </p>
        </div>
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
                    <DownloadButton pdfPath={s.pdf_path ?? ""} />
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
