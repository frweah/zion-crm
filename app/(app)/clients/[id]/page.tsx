import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { CAN_EDIT_CLIENTS } from "@/lib/constants";
import {
  StageControl,
  DetailsForm,
  RestrictedPanel,
  type ClientDetail,
} from "./client-detail";
import { NotesTab, type NoteRow } from "./notes-tab";
import { TasksTab, type TaskRow } from "./tasks-tab";

/** Tab order follows the prototype's drawer. */
const TABS = [
  { key: "overview", label: "Overview", built: true },
  { key: "intake", label: "Intake", built: false, needsEdit: true },
  { key: "notes", label: "Notes", built: true },
  { key: "forms", label: "Forms", built: false },
  { key: "report", label: "Report", built: false },
  { key: "placements", label: "Placements", built: false },
  { key: "tasks", label: "Tasks", built: true },
  { key: "authorizations", label: "Authorizations", built: false, billing: true },
  { key: "payments", label: "Payments", built: false, billing: true },
];

export default async function ClientPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ tab?: string }>;
}) {
  const { id } = await params;
  const { tab: rawTab } = await searchParams;
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

  const canEdit = CAN_EDIT_CLIENTS.includes(me.role);
  const isAdmin = me.role === "Admin";
  const canSeeBilling = me.role === "Admin" || me.role === "Billing";
  const detail = client as ClientDetail;

  const tabs = TABS.filter((t) => (t.billing ? canSeeBilling : true)).filter((t) =>
    t.needsEdit ? canEdit : true,
  );
  const tab = tabs.some((t) => t.key === rawTab) ? rawTab! : "overview";
  const active = tabs.find((t) => t.key === tab)!;

  const canSeeRestricted =
    me.role === "Admin" || me.role === "Reports" || client.assigned_staff_id === me.id;

  const header = (
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
            {detail.agency_id ? `USOR ID ${detail.agency_id} · ` : ""}
            {detail.funding_source}
          </p>
        </div>
        <span className="chip gold">{detail.stage}</span>
      </div>

      <nav className="tabs">
        {tabs.map((t) => (
          <Link
            key={t.key}
            href={`/clients/${id}?tab=${t.key}`}
            className={t.key === tab ? "on" : ""}
          >
            {t.label}
            {!t.built && " ·"}
          </Link>
        ))}
      </nav>
    </>
  );

  if (tab === "notes") {
    const { data } = await supabase
      .from("notes")
      .select("id, text, type, ts, at, staff_name, visible_roles")
      .eq("client_id", id)
      .order("ts", { ascending: false });

    return (
      <>
        {header}
        <NotesTab clientId={id} notes={(data ?? []) as NoteRow[]} myName={me.name} />
      </>
    );
  }

  if (tab === "tasks") {
    const [tasksResult, staffResult] = await Promise.all([
      supabase
        .from("tasks")
        .select("id, title, due, status, done_at, assigned_staff_id, system_generated")
        .eq("client_id", id)
        .order("due", { nullsFirst: false }),
      supabase.from("staff").select("id, name").eq("active", true).order("name"),
    ]);

    const staff = staffResult.data ?? [];
    const staffName = new Map(staff.map((s) => [s.id, s.name]));
    const tasks: TaskRow[] = (tasksResult.data ?? []).map((t) => ({
      id: t.id,
      title: t.title,
      due: t.due,
      status: t.status,
      done_at: t.done_at,
      system_generated: t.system_generated,
      assigned_name: t.assigned_staff_id ? (staffName.get(t.assigned_staff_id) ?? "") : "",
    }));

    return (
      <>
        {header}
        <TasksTab clientId={id} tasks={tasks} staff={staff} myId={me.id} />
      </>
    );
  }

  if (!active.built) {
    return (
      <>
        {header}
        <div className="card">
          <h3>{active.label}</h3>
          <p className="sub" style={{ margin: 0 }}>
            Not ported yet. This tab arrives with the rest of the Phase 2 port.
          </p>
        </div>
      </>
    );
  }

  const [privateResult, counselorsResult, staffResult, officesResult, historyResult] =
    await Promise.all([
      // A null here means the restricted policy declined, not that the row is
      // missing — which is the distinction the panel renders.
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

  return (
    <>
      {header}

      {detail.import_review && (
        <div className="alert" style={{ marginBottom: 12 }}>
          <b>Flagged during import:</b> {detail.import_review}
        </div>
      )}

      <div className="grid" style={{ gridTemplateColumns: "minmax(0, 2fr) minmax(260px, 1fr)" }}>
        <div className="grid">
          <DetailsForm
            client={detail}
            counselors={counselorsResult.data ?? []}
            staff={staffResult.data ?? []}
            offices={(officesResult.data ?? []).map((o) => o.name)}
            canEdit={canEdit}
            isAdmin={isAdmin}
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
        </div>
      </div>
    </>
  );
}
