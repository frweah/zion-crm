import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { RecordHeader } from "../../record-header";
import { DataTable } from "../../data-table";
import {
  AddMatchForm,
  LeadStatusControl,
  MatchPlacementControl,
  MatchStatusControl,
} from "../leads-forms";

const CAN_EDIT = ["Admin", "Job Search"];

/** An opening's status is worth a chip beside its name once it has stopped being worked. */
const QUIET_STATUSES = ["Filled", "Closed"];

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

  const sortedMatches = matches
    .slice()
    .sort((a, b) =>
      (clientName.get(a.client_id) ?? "").localeCompare(clientName.get(b.client_id) ?? ""),
    );

  return (
    <>
      <RecordHeader
        back={{ href: "/leads", label: "Jobs" }}
        title={lead.title}
        status={QUIET_STATUSES.includes(lead.status) ? lead.status : null}
        identity={
          employer
            ? [
                employer.name,
                employer.industry,
                employer.relationship_status === "Do not use" ? (
                  <span className="chip bad">do not use</span>
                ) : null,
              ]
            : ["—"]
        }
        actions={
          canEdit ? (
            <LeadStatusControl leadId={lead.id} status={lead.status} />
          ) : (
            <span className="chip gold">{lead.status}</span>
          )
        }
      />

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
            <DataTable
              label="clients"
              columns={[
                { key: "client", label: "Client" },
                { key: "status", label: "Where things stand" },
                { key: "dates", label: "Dates" },
                { key: "placement", label: "Placement", sortable: canEdit ? false : undefined },
              ]}
              rows={sortedMatches.map((m) => {
                const name = clientName.get(m.client_id) ?? "—";
                const match = { ...m, client_name: name };
                return {
                  key: m.id,
                  sort: {
                    client: name,
                    status: m.status,
                    dates: m.interview_on ?? m.applied_on ?? m.decided_on,
                    placement: m.placement_id ? 1 : 0,
                  },
                  text: [name, m.status, m.notes].filter(Boolean).join(" "),
                  cells: {
                    client: (
                      <>
                        <Link
                          href={`/clients/${m.client_id}`}
                          style={{ color: "inherit", fontWeight: canEdit ? 600 : undefined }}
                        >
                          {name}
                        </Link>
                        {canEdit && m.notes && (
                          <div style={{ fontSize: 12, color: "var(--muted)" }}>{m.notes}</div>
                        )}
                      </>
                    ),
                    status: canEdit ? (
                      <MatchStatusControl matchId={m.id} leadId={lead.id} status={m.status} />
                    ) : (
                      <span className="chip">{m.status}</span>
                    ),
                    dates: (
                      <span style={{ fontSize: 12, color: "var(--muted)", whiteSpace: "nowrap" }}>
                        {m.applied_on && <div>applied {m.applied_on}</div>}
                        {m.interview_on && <div>interview {m.interview_on}</div>}
                        {canEdit && m.decided_on && <div>decided {m.decided_on}</div>}
                      </span>
                    ),
                    placement: canEdit ? (
                      <MatchPlacementControl match={match} leadId={lead.id} />
                    ) : m.placement_id ? (
                      <span className="chip ok">recorded</span>
                    ) : (
                      "—"
                    ),
                  },
                };
              })}
              empty="Nobody has been put forward for this opening yet."
            />
          </div>
        </div>

        <div className="grid" style={{ alignContent: "start" }}>
          <div className="card">
            <h3>The opening</h3>
            <table className="t" data-layout="key and value details of the opening">
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
