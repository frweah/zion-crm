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
import { IntakeTab, type IntakeRow } from "./intake-tab";
import { FormsTab, type FormRow, type AuthChoice } from "./forms-tab";
import { FilesTab, type AttachmentRow } from "./files-tab";
import { templatesForService } from "@/lib/form-templates";
import { PlacementsTab, type PlacementRow } from "./placements-tab";
import { ReportTab } from "./report-tab";
import { buildReportText, type ReportPeriod } from "@/lib/report";
import { money, periodRange, today, CAN_EDIT_BILLING } from "@/lib/constants";

/** Tab order follows the prototype's drawer. */
const TABS = [
  { key: "overview", label: "Overview", built: true },
  { key: "intake", label: "Intake", built: true, needsEdit: true },
  { key: "notes", label: "Notes", built: true },
  { key: "forms", label: "Forms", built: true },
  { key: "files", label: "Files", built: true },
  { key: "report", label: "Report", built: true },
  { key: "placements", label: "Placements", built: true },
  { key: "tasks", label: "Tasks", built: true },
  { key: "authorizations", label: "Authorizations", built: true, billing: true },
  { key: "payments", label: "Payments", built: true, billing: true },
];

export default async function ClientPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ tab?: string; kind?: string; anchor?: string }>;
}) {
  const { id } = await params;
  const { tab: rawTab, kind: rawKind, anchor: rawAnchor } = await searchParams;
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

  if (tab === "intake") {
    // A null row here can mean either "no intake yet" or "the policy declined",
    // so the tab is told separately whether this staff member may see one.
    const { data } = await supabase
      .from("intakes")
      .select(
        "phone, email, address, emergency_name, emergency_phone, goals, availability, transportation, accommodations, submitted_at, updated_on",
      )
      .eq("client_id", id)
      .maybeSingle();

    return (
      <>
        {header}
        <IntakeTab
          clientId={id}
          clientName={detail.name}
          intake={(data as IntakeRow | null) ?? null}
          visible={canSeeRestricted}
          canEdit={canEdit}
        />
      </>
    );
  }

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

  if (tab === "forms") {
    const [formsResult, authsResult] = await Promise.all([
      supabase
        .from("forms")
        .select(
          "id, template_id, status, month, auth_id, created_at, completed_at, completed_by_name, sent_to",
        )
        .eq("client_id", id)
        .order("created_at", { ascending: false }),
      supabase
        .from("authorizations")
        .select("id, number, service_type, status")
        .eq("client_id", id)
        .order("number"),
    ]);

    const forms = (formsResult.data ?? []) as FormRow[];
    const auths = authsResult.data ?? [];

    const authChoices: AuthChoice[] = auths.map((a) => ({
      id: a.id,
      label: `${a.number || "(no number)"} · ${a.service_type}`,
      serviceType: a.service_type,
    }));

    // The same test the database applies before letting an invoice be sent,
    // shown here where the work to clear it actually happens.
    const missingForBilling = auths
      .filter((a) => a.status === "Open")
      .map((a) => ({
        authLabel: `${a.number || a.service_type}`,
        usor: templatesForService(a.service_type)
          .filter(
            (t) =>
              t.requiredForBilling &&
              !forms.some((f) => f.auth_id === a.id && f.template_id === t.id && f.status !== "Draft"),
          )
          .map((t) => t.usor),
      }))
      .filter((m) => m.usor.length > 0);

    return (
      <>
        {header}
        <FormsTab
          clientId={id}
          forms={forms}
          auths={authChoices}
          missingForBilling={missingForBilling}
        />
      </>
    );
  }

  if (tab === "files") {
    // Restricted documents are filtered out by RLS, not here — a staff member
    // without access does not learn that they exist.
    const { data } = await supabase
      .from("attachments")
      .select(
        "id, storage_path, filename, mime_type, size_bytes, category, restricted, note, uploaded_by_name, created_at",
      )
      .eq("client_id", id)
      .order("created_at", { ascending: false });

    return (
      <>
        {header}
        <FilesTab
          clientId={id}
          files={(data ?? []) as AttachmentRow[]}
          canSeeRestricted={canSeeRestricted}
        />
      </>
    );
  }

  if (tab === "placements") {
    const { data } = await supabase
      .from("placements")
      .select(
        "id, employer, title, start_date, wage, hours_week, check30, check60, check90, jp_submitted, jp_paid",
      )
      .eq("client_id", id)
      .order("start_date", { ascending: false, nullsFirst: false });

    return (
      <>
        {header}
        <PlacementsTab
          clientId={id}
          placements={(data ?? []) as PlacementRow[]}
          canEdit={canEdit}
          canBill={CAN_EDIT_BILLING.includes(me.role)}
        />
      </>
    );
  }

  if (tab === "report") {
    const kind: ReportPeriod = rawKind === "Monthly" ? "Monthly" : "Weekly";
    const anchor = /^\d{4}-\d{2}-\d{2}$/.test(rawAnchor ?? "") ? rawAnchor! : today();
    const [start, end] = periodRange(kind, anchor);
    const { text } = await buildReportText(id, kind, start, end);

    return (
      <>
        {header}
        <ReportTab
          clientId={id}
          clientName={detail.name}
          kind={kind}
          anchor={anchor}
          start={start}
          end={end}
          text={text}
        />
      </>
    );
  }

  if (tab === "authorizations") {
    const { data: auths } = await supabase
      .from("authorizations")
      .select(
        "id, number, service_type, total_hours, carried_used, rate_type, rate, start_date, end_date, status, requires_forms",
      )
      .eq("client_id", id)
      .order("start_date", { ascending: false, nullsFirst: false });

    const authIds = (auths ?? []).map((a) => a.id);
    const { data: entries } = authIds.length
      ? await supabase
          .from("service_entries")
          .select("auth_id, hours, non_billable")
          .in("auth_id", authIds)
      : { data: [] };

    // Hours used = what was carried over at migration plus everything logged.
    const logged = new Map<string, number>();
    for (const e of entries ?? []) {
      if (e.non_billable) continue;
      logged.set(e.auth_id, (logged.get(e.auth_id) ?? 0) + Number(e.hours));
    }

    return (
      <>
        {header}
        {(auths ?? []).length === 0 && (
          <div className="empty">No authorizations on file. Add them from Billing.</div>
        )}
        {(auths ?? []).map((a) => {
          const used = Number(a.carried_used ?? 0) + (logged.get(a.id) ?? 0);
          const total = a.total_hours ? Number(a.total_hours) : null;
          const remaining = total === null ? null : total - used;
          const pct = total ? Math.min(100, (used / total) * 100) : 0;
          const tone = remaining === null ? "" : remaining <= 0 ? "bad" : pct >= 90 ? "warn" : "";

          return (
            <div key={a.id} className="card" style={{ marginBottom: 10 }}>
              <div className="row2" style={{ justifyContent: "space-between" }}>
                <b>{a.number || "(no authorization number)"}</b>
                <span className="chip gold">{a.service_type}</span>
              </div>
              <div style={{ fontSize: 13, marginTop: 6 }}>
                {a.rate_type === "Hourly" && total !== null
                  ? `${total} hrs @ ${money(a.rate)} · used ${used} · ${remaining} remaining`
                  : `Flat fee ${money(a.rate)}`}
              </div>
              {total !== null && (
                <div className="bar" style={{ marginTop: 6 }}>
                  <i className={tone} style={{ width: `${pct}%` }} />
                </div>
              )}
              <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 6 }}>
                {a.start_date || "—"} → {a.end_date || "—"} · {a.status}
                {a.requires_forms && ` · needs: ${a.requires_forms}`}
              </div>
            </div>
          );
        })}
      </>
    );
  }

  if (tab === "payments") {
    const { data: auths } = await supabase
      .from("authorizations")
      .select("id, number, service_type")
      .eq("client_id", id);

    const authIds = (auths ?? []).map((a) => a.id);
    const authById = new Map((auths ?? []).map((a) => [a.id, a]));

    const { data: invoices } = authIds.length
      ? await supabase
          .from("invoices")
          .select("id, auth_id, number, date, amount, status, warrant, service_type, paid_date")
          .in("auth_id", authIds)
          .order("date", { ascending: false })
      : { data: [] };

    const rows = invoices ?? [];
    const totalPaid = rows
      .filter((i) => i.status === "Paid")
      .reduce((t, i) => t + Number(i.amount), 0);

    return (
      <>
        {header}
        {rows.length === 0 ? (
          <div className="empty">No payments on record.</div>
        ) : (
          <div className="card" style={{ padding: 0 }}>
            <div style={{ fontSize: 13, padding: "12px 16px" }}>
              Total paid: <b>{money(totalPaid)}</b> across {rows.length} payment
              {rows.length === 1 ? "" : "s"}
            </div>
            <table className="t">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Auth #</th>
                  <th>Service</th>
                  <th>Amount</th>
                  <th>Status</th>
                  <th>Warrant</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((i) => (
                  <tr key={i.id}>
                    <td>{i.date}</td>
                    <td>{i.number}</td>
                    <td>{i.service_type || authById.get(i.auth_id)?.service_type || ""}</td>
                    <td>{money(i.amount)}</td>
                    <td>
                      <span className={"chip " + (i.status === "Paid" ? "ok" : "")}>
                        {i.status}
                      </span>
                    </td>
                    <td style={{ fontSize: 12, color: "var(--muted)" }}>{i.warrant}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
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
            The DWS-USOR form engine is Phase 4, together with emailing completed forms to the
            counselor. Until then, forms are filled in and sent as they are today.
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
