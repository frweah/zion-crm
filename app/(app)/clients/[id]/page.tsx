import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import {
  StageControl,
  DetailsForm,
  RestrictedPanel,
  type ClientDetail,
} from "./client-detail";

const CAN_EDIT = ["Admin", "Job Search", "Reports"];

export default async function ClientPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const me = await requireStaff();
  const supabase = await createClient();

  const { data: client } = await supabase
    .from("clients")
    .select(
      "id, name, client_no, agency_id, funding_source, phone, email, counselor_id, counselor_contact, referring_office, caseload, unit, schedule, target_jobs, assigned_staff_id, status, stage, wsa_tier, wsa_completed, import_review",
    )
    .eq("id", id)
    .maybeSingle();

  if (!client) notFound();

  // A null result here means the restricted policy declined, not that the row
  // is missing — which is exactly the distinction the panel renders.
  const [privateResult, counselorsResult, staffResult, officesResult, historyResult] =
    await Promise.all([
      supabase.from("client_private").select("dob, address").eq("client_id", id).maybeSingle(),
      supabase.from("counselors").select("id, name").order("name"),
      supabase.from("staff").select("id, name").eq("active", true).order("name"),
      supabase.from("offices").select("name").order("name"),
      supabase
        .from("client_stage_history")
        .select("stage, at")
        .eq("client_id", id)
        .order("at", { ascending: false })
        .limit(8),
    ]);

  const canSeeRestricted =
    me.role === "Admin" || me.role === "Reports" || client.assigned_staff_id === me.id;

  const canEdit = CAN_EDIT.includes(me.role);
  const detail = client as ClientDetail;

  return (
    <>
      <p className="sub" style={{ marginBottom: 8 }}>
        <Link href="/clients" style={{ color: "var(--teal)" }}>
          ← Clients
        </Link>
      </p>

      <div className="row2" style={{ justifyContent: "space-between", marginBottom: 4 }}>
        <div>
          <h1 className="h1">
            {detail.name}
            {detail.status !== "Active" && (
              <span className="chip" style={{ marginLeft: 10, verticalAlign: "middle" }}>
                {detail.status}
              </span>
            )}
          </h1>
          <p className="sub" style={{ margin: 0 }}>
            {detail.client_no ? `Client #${detail.client_no} · ` : ""}
            {detail.funding_source}
            {detail.agency_id ? ` · agency ID ${detail.agency_id}` : ""}
          </p>
        </div>
        <span className="chip gold">{detail.stage}</span>
      </div>

      {detail.import_review && (
        <div className="alert" style={{ marginTop: 12 }}>
          <b>Flagged during import:</b> {detail.import_review}
        </div>
      )}

      <div
        className="grid"
        style={{ gridTemplateColumns: "minmax(0, 2fr) minmax(260px, 1fr)", marginTop: 14 }}
      >
        <div className="grid">
          <DetailsForm
            client={detail}
            counselors={counselorsResult.data ?? []}
            staff={staffResult.data ?? []}
            offices={(officesResult.data ?? []).map((o) => o.name)}
            canEdit={canEdit}
          />
          <RestrictedPanel
            clientId={detail.id}
            dob={privateResult.data?.dob ?? null}
            address={privateResult.data?.address ?? ""}
            visible={canSeeRestricted}
            canEdit={canEdit}
          />
        </div>

        <div className="grid" style={{ alignContent: "start" }}>
          <StageControl client={detail} canEdit={canEdit} />

          <div className="card">
            <h3>Stage history</h3>
            {(historyResult.data ?? []).length === 0 ? (
              <div className="empty">Nothing recorded yet.</div>
            ) : (
              <table className="t">
                <tbody>
                  {(historyResult.data ?? []).map((h, i) => (
                    <tr key={i}>
                      <td>{h.stage}</td>
                      <td style={{ color: "var(--muted)" }}>{h.at}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>

          <div className="card">
            <h3>Still to come</h3>
            <p className="sub" style={{ margin: 0 }}>
              Notes, tasks, intake, placements, forms and the activity report are the next
              components in the Phase 2 port.
            </p>
          </div>
        </div>
      </div>
    </>
  );
}
