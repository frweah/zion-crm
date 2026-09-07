import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { AddMatchForm, MatchRow, LeadStatusControl } from "../leads-forms";

const CAN_EDIT = ["Admin", "Job Search"];

export default async function LeadPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const me = await requireStaff();
  const canEdit = CAN_EDIT.includes(me.role);
  const supabase = await createClient();

  const { data: lead } = await supabase
    .from("job_leads")
    .select(
      "id, employer_id, title, wage_range, hours_week, shift, requirements, source, posted_date, status, owner_staff_id",
    )
    .eq("id", id)
    .maybeSingle();

  if (!lead) notFound();

  const [employerResult, matchesResult, clientsResult, staffResult] = await Promise.all([
    supabase
      .from("employers")
      .select("id, name, industry, contact_name, contact_phone, contact_email, relationship_status")
      .eq("id", lead.employer_id)
      .maybeSingle(),
    supabase
      .from("lead_matches")
      .select("id, client_id, status, applied_on, interview_on, decided_on, notes, placement_id")
      .eq("lead_id", id),
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
    supabase.from("staff").select("id, name"),
  ]);

  const employer = employerResult.data;
  const clients = clientsResult.data ?? [];
  const clientName = new Map(clients.map((c) => [c.id, c.name]));
  const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));

  // A client already on this opening should not be offered again.
  const matches = matchesResult.data ?? [];
  const taken = new Set(matches.map((m) => m.client_id));
  const available = clients.filter((c) => !taken.has(c.id));

  return (
    <>
      <p className="sub" style={{ marginBottom: 8 }}>
        <Link href="/leads" style={{ color: "var(--teal)" }}>
          ← Job leads
        </Link>
      </p>

      <div className="row2" style={{ justifyContent: "space-between", marginBottom: 4 }}>
        <div>
          <h1 className="h1">{lead.title}</h1>
          <p className="sub" style={{ margin: 0 }}>
            {employer ? (
              <>
                {employer.name}
                {employer.industry ? ` · ${employer.industry}` : ""}
                {employer.relationship_status === "Do not use" && (
                  <span className="chip bad" style={{ marginLeft: 8 }}>
                    do not use
                  </span>
                )}
              </>
            ) : (
              "—"
            )}
          </p>
        </div>
        {canEdit ? (
          <LeadStatusControl leadId={lead.id} status={lead.status} />
        ) : (
          <span className="chip gold">{lead.status}</span>
        )}
      </div>

      <div
        className="grid"
        style={{ gridTemplateColumns: "minmax(0, 2fr) minmax(240px, 1fr)", marginTop: 14 }}
      >
        <div>
          {canEdit && available.length > 0 && (
            <AddMatchForm leadId={lead.id} clients={available} />
          )}
          {canEdit && available.length === 0 && clients.length > 0 && (
            <div className="alert">Every active client is already on this opening.</div>
          )}

          <div className="card" style={{ padding: 0 }}>
            <table className="t">
              <thead>
                <tr>
                  <th>Client</th>
                  <th>Where things stand</th>
                  <th>Dates</th>
                  <th>Placement</th>
                </tr>
              </thead>
              <tbody>
                {matches.length === 0 && (
                  <tr>
                    <td colSpan={4} className="empty">
                      Nobody put forward yet.
                    </td>
                  </tr>
                )}
                {matches
                  .slice()
                  .sort((a, b) =>
                    (clientName.get(a.client_id) ?? "").localeCompare(
                      clientName.get(b.client_id) ?? "",
                    ),
                  )
                  .map((m) =>
                    canEdit ? (
                      <MatchRow
                        key={m.id}
                        leadId={lead.id}
                        match={{ ...m, client_name: clientName.get(m.client_id) ?? "—" }}
                      />
                    ) : (
                      <tr key={m.id}>
                        <td>
                          <Link href={`/clients/${m.client_id}`} style={{ color: "inherit" }}>
                            {clientName.get(m.client_id) ?? "—"}
                          </Link>
                        </td>
                        <td>
                          <span className="chip">{m.status}</span>
                        </td>
                        <td style={{ fontSize: 12, color: "var(--muted)" }}>
                          {m.applied_on && <div>applied {m.applied_on}</div>}
                          {m.interview_on && <div>interview {m.interview_on}</div>}
                        </td>
                        <td>
                          {m.placement_id ? <span className="chip ok">recorded</span> : "—"}
                        </td>
                      </tr>
                    ),
                  )}
              </tbody>
            </table>
          </div>
        </div>

        <div className="grid" style={{ alignContent: "start" }}>
          <div className="card">
            <h3>The opening</h3>
            <table className="t">
              <tbody>
                <tr><td>Wage</td><td>{lead.wage_range || "—"}</td></tr>
                <tr><td>Hours/week</td><td>{lead.hours_week || "—"}</td></tr>
                <tr><td>Shift</td><td>{lead.shift || "—"}</td></tr>
                <tr><td>Source</td><td>{lead.source || "—"}</td></tr>
                <tr><td>Posted</td><td>{lead.posted_date ?? "—"}</td></tr>
                <tr>
                  <td>Owner</td>
                  <td>{lead.owner_staff_id ? (staffName.get(lead.owner_staff_id) ?? "—") : "—"}</td>
                </tr>
              </tbody>
            </table>
            {lead.requirements && (
              <p style={{ fontSize: 13, marginTop: 10, whiteSpace: "pre-wrap" }}>
                {lead.requirements}
              </p>
            )}
          </div>

          {employer && (
            <div className="card">
              <h3>Employer contact</h3>
              <div style={{ fontSize: 13 }}>
                {employer.contact_name && <div>{employer.contact_name}</div>}
                {employer.contact_phone && <div>{employer.contact_phone}</div>}
                {employer.contact_email && <div>{employer.contact_email}</div>}
                {!employer.contact_name && !employer.contact_phone && !employer.contact_email && (
                  <span className="lock">No contact recorded.</span>
                )}
              </div>
            </div>
          )}
        </div>
      </div>
    </>
  );
}
