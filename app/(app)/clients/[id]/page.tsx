import { can, ORG } from "@/lib/roles";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { CAN_EDIT_CLIENTS, money, periodRange, today } from "@/lib/constants";
import { StageControl, DetailsForm, RestrictedPanel, type ClientDetail } from "./client-detail";
import { NotesTab, type NoteRow } from "./notes-tab";
import { AuthorizationFiles } from "./authorization-files";
import { type TaskRow } from "./tasks-tab";
import { IntakeTab, type IntakeRow } from "./intake-tab";
import { FormsTab, type FormRow, type AuthChoice } from "./forms-tab";
import { FilesTab, type AttachmentRow } from "./files-tab";
import { templatesForService } from "@/lib/form-templates";
import { PlacementsTab, type PlacementRow } from "./placements-tab";
import { ReportTab } from "./report-tab";
import { ComingUp, type EventRow } from "./calendar-tab";
import { ActivityTab, ACTIVITY_KINDS, type ActivityRow } from "./activity-tab";
import { JobsPanel, type JobRow } from "./jobs-panel";
import { PaperworkStrip, type PaperworkRow } from "./paperwork-strip";
import { WhatsNext, StatusLine, type NextAction } from "./whats-next";
import { COACHING_CODES, CAN_LOG_HOURS } from "@/lib/constants";
import type { BillOption, VisitAuth } from "./record-actions";
import { TextingPanel, type ConsentRow, type TextRow } from "./texting-panel";
import { TextThread } from "./messages-tab";
import { RecordActions } from "./record-actions";
import { RecordHeader } from "../../record-header";
import { DataTable } from "../../data-table";
import { AuthorizationPayments } from "./authorization-payments";
import { WarrantLink } from "../../billing/warrants/warrant-link";
import { readPayments } from "@/lib/payments";
import { buildReportText, type ReportPeriod } from "@/lib/report";
import { presetByKey } from "@/lib/report-presets";
import { CLIENT_TABS, MOVED_CLIENT_TABS, isClientTab, type ClientTab } from "@/lib/client-tabs";

type Params = {
  tab?: string;
  kind?: string;
  anchor?: string;
  days?: string;
  preset?: string;
  report?: string;
  intake?: string;
};

/**
 * A client's record: six tabs, and the record's actions in its header.
 *
 * Activity (what is coming up, then everything that happened) · Profile ·
 * Notes · Jobs · Billing · Documents. The twelve tabs before the consolidation
 * each live inside one of these (lib/client-tabs.ts), and an old ?tab= is
 * redirected rather than dropped.
 */
export default async function ClientPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Params>;
}) {
  const { id } = await params;
  const sp = await searchParams;

  // ── an old tab goes where it went ──────────────────────────
  if (sp.tab && !isClientTab(sp.tab) && MOVED_CLIENT_TABS[sp.tab]) {
    const moved = MOVED_CLIENT_TABS[sp.tab];
    const qs = new URLSearchParams();
    qs.set("tab", moved.tab);
    for (const [k, v] of Object.entries(sp)) {
      if (k !== "tab" && k !== "kind" && typeof v === "string" && v) qs.set(k, v);
    }
    // The report tab took its period as ?kind=; the dialog takes it as ?report=.
    if (moved.report) qs.set("report", sp.kind === "Monthly" ? "Monthly" : "Weekly");
    else if (sp.kind) qs.set("kind", sp.kind);
    redirect(`/clients/${id}?${qs.toString()}${moved.hash ? `#${moved.hash}` : ""}`);
  }

  const me = await requireStaff();
  const supabase = await createClient();

  // The client, their counselor and the staff list at once. The counselor was
  // looked up after the client came back, which put a whole round trip in
  // front of every tab; asking through the client's own link to the counselor
  // lets all three go together.
  const [{ data: client }, { data: counselorLink }, { data: staffRows }] = await Promise.all([
    supabase
    .from("clients")
    .select(
      "id, name, client_no, agency_id, funding_source, phone, email, counselor_id, counselor_contact, referring_office, caseload, unit, schedule, target_jobs, assigned_staff_id, status, stage, wsa_tier, wsa_completed, import_review",
    )
    .eq("id", id)
    .maybeSingle(),
    supabase
      .from("clients")
      .select("counselor:counselors!clients_counselor_id_fkey(name, email)")
      .eq("id", id)
      .maybeSingle() as unknown as Promise<{ data: { counselor: { name: string; email: string | null } | null } | null }>,
    supabase.from("staff").select("id, name").eq("active", true).order("name"),
  ]);

  if (!client) notFound();

  const detail = client as ClientDetail;

  // ── what this record needs, and what can be done to it ─────
  // Asked together, after the client is known: each one needs the id, and
  // none of them needs any of the others.
  const [
    { data: nextRows },
    { data: openAuths },
    { data: paperworkRows },
    { data: billingOfficeRow },
    { data: consentRow },
    { data: economics },
    { data: authFiles },
  ] = await Promise.all([
    supabase.rpc("client_next_actions", { p_client: id }),
    supabase
      .from("authorizations")
      .select("id, number, service_type, rate, rate_type, total_hours, status")
      .eq("client_id", id)
      .eq("status", "Open")
      .order("end_date", { ascending: true, nullsFirst: false }),
    supabase.from("client_paperwork").select("auth_id, template_id, state, month").eq("client_id", id),
    supabase.from("client_billing_office").select("billing_office").eq("client_id", id).maybeSingle(),
    supabase.from("client_sms_consent").select("can_text, state").eq("client_id", id).maybeSingle(),
    supabase.from("authorization_economics").select("auth_id, unbilled").eq("client_id", id),
    // Whether each authorization has its own PDF on the record, so the
    // billing panel can say what will actually go with the claim.
    supabase.from("attachments").select("auth_id").eq("client_id", id).not("auth_id", "is", null),
  ]);

  // Opening a record puts it at the top of this person's recents, which is
  // what the search box offers before anybody types.
  await supabase.rpc("note_client_opened", { p_client: id });

  const nextActions = (nextRows ?? []) as NextAction[];
  const unbilledTotal = (economics ?? []).reduce((sum, e) => sum + Number(e.unbilled ?? 0), 0);

  // "100 hrs @ $45.00", or "$2,250.00 flat" - the way the authorization reads.
  const priceOf = (a: { rate: number | null; rate_type: string; total_hours: number | null }) =>
    a.rate_type === "Hourly" && a.total_hours != null
      ? `${Number(a.total_hours)} hrs @ ${money(Number(a.rate ?? 0))}`
      : `${money(Number(a.rate ?? 0))} flat`;

  const authLabel = (a: {
    number: string | null;
    service_type: string;
    rate: number | null;
    rate_type: string;
    total_hours: number | null;
    status: string;
  }) => `${a.service_type} · ${a.number || "no V-number"} · ${priceOf(a)} · ${a.status}`;

  const withAuthPdf = new Set((authFiles ?? []).map((f) => f.auth_id).filter(Boolean) as string[]);

  const visitAuths: VisitAuth[] = (openAuths ?? []).map((a) => ({ id: a.id, label: authLabel(a) }));

  // Which form each authorization bills on, and whether it is still wanted.
  const billingForms = paperworkRows ?? [];
  const bills: BillOption[] = (openAuths ?? [])
    .map((a) => ({
      authId: a.id,
      label: authLabel(a),
      service: a.service_type,
      number: a.number ?? "",
      price: priceOf(a),
      status: a.status,
      hasPdf: withAuthPdf.has(a.id),
      templates: templatesForService(a.service_type)
        .filter((t) => t.requiredForBilling)
        .map((t) => ({
          id: t.id,
          usor: t.usor,
          name: t.name,
          monthly: Boolean(t.monthly),
          outstanding: billingForms.some(
            (p) => p.auth_id === a.id && p.template_id === t.id && p.state !== "Complete",
          ),
        })),
    }))
    .filter((b) => b.templates.length > 0);
  const canEdit = CAN_EDIT_CLIENTS.includes(me.role);
  const canBill = can(me, "billing", "edit");
  const isAdmin = me.role === "Admin";
  const canSeeRestricted =
    me.role === "Admin" || me.role === "Reports" || client.assigned_staff_id === me.id;
  const tab: ClientTab = isClientTab(sp.tab) ? sp.tab : "activity";

  const counselor = counselorLink?.counselor ?? null;
  const staff = staffRows ?? [];
  const staffName = new Map(staff.map((s) => [s.id, s.name]));
  const assignedName = client.assigned_staff_id ? staffName.get(client.assigned_staff_id) : undefined;

  // The record's own tabs sit directly under its header; they are the only
  // tabs on this screen.
  const header = (
    <>
      <RecordHeader
        back={{ href: "/clients", label: "Clients" }}
        title={detail.name}
        status={detail.status !== "Active" ? detail.status : null}
        identity={[
          detail.client_no ? `Client #${detail.client_no}` : null,
          detail.agency_id ? `USOR ID ${detail.agency_id}` : null,
          detail.funding_source,
        ]}
        standing={
          <>
            <StatusLine
              stage={detail.stage}
              assignedName={assignedName ?? null}
              counselorName={counselor?.name ?? null}
              billingOffice={billingOfficeRow?.billing_office ?? null}
              canText={Boolean(consentRow?.can_text)}
              consentState={consentRow?.state ?? null}
              unbilled={unbilledTotal}
              clientId={id}
            />
          </>
        }
        actions={
          <RecordActions
            clientId={id}
            clientName={detail.name}
            tab={tab}
            staff={staff}
            myId={me.id}
            canLogHours={CAN_LOG_HOURS.includes(me.role) || canBill}
            visitAuths={visitAuths}
            bills={bills}
            coachingCodes={[...COACHING_CODES]}
            counselorEmail={counselor?.email ?? null}
            counselorName={counselor?.name ?? ""}
            agency={ORG.name}
            preparedBy={me.name}
            billingOffice={billingOfficeRow?.billing_office ?? null}
          />
        }
      />

      <WhatsNext items={nextActions} />

      <nav className="tabs">
        {CLIENT_TABS.map((t) => (
          <Link key={t.key} href={`/clients/${id}?tab=${t.key}`} className={t.key === tab ? "on" : ""}>
            {t.label}
          </Link>
        ))}
      </nav>
    </>
  );

  // ── Send report, as a dialog over whichever tab is open ────
  let overlay: React.ReactNode = null;
  if (sp.report === "Weekly" || sp.report === "Monthly") {
    const kind: ReportPeriod = sp.report;
    const anchor = /^\d{4}-\d{2}-\d{2}$/.test(sp.anchor ?? "") ? sp.anchor! : today();
    const preset = presetByKey(sp.preset);
    const [start, end] = periodRange(kind, anchor);
    const { text } = await buildReportText(id, kind, start, end, preset.key);
    overlay = (
      <div
        style={{
          position: "fixed",
          inset: 0,
          background: "var(--scrim)",
          zIndex: 40,
          overflowY: "auto",
          padding: "5vh 16px",
        }}
      >
        <div role="dialog" aria-label={`Send a progress report for ${detail.name}`} style={{ maxWidth: 880, margin: "0 auto" }}>
          <div className="card" style={{ marginBottom: 12 }}>
            <div className="row2" style={{ justifyContent: "space-between" }}>
              <h3 style={{ margin: 0 }}>Send report · {detail.name}</h3>
              <Link className="btn ghost" href={`/clients/${id}?tab=${tab}`} style={{ textDecoration: "none" }}>
                Close
              </Link>
            </div>
          </div>
          <ReportTab
            clientId={id}
            returnTab={tab}
            clientName={detail.name}
            kind={kind}
            preset={preset.key}
            anchor={anchor}
            start={start}
            end={end}
            text={text}
            counselorName={counselor?.name ?? ""}
            counselorEmail={(counselor?.email ?? "").trim()}
            canSend={canEdit}
          />
        </div>
      </div>
    );
  }

  // ── Messages: the client's texts, both ways (Messaging brief, A) ──
  if (tab === "messages") {
    const [{ data: conv }, { data: consent }, { data: templates }, { data: scheduled }, { data: window }] = await Promise.all([
      supabase.from("conversations").select("id").eq("kind", "sms").eq("client_id", id).maybeSingle(),
      supabase.from("client_sms_consent").select("can_text, consented_phone, client_phone, state").eq("client_id", id).maybeSingle(),
      supabase.from("sms_templates").select("id, label, body").eq("active", true).order("sort_order"),
      supabase.from("sms_messages").select("id, body, send_after").eq("client_id", id).eq("status", "Scheduled").order("send_after"),
      supabase.rpc("next_text_window", { p_at: new Date().toISOString() }),
    ]);

    const { data: thread } = conv
      ? await supabase
          .from("messages")
          .select("id, seq, sender_kind, sender_label, body, status, created_at")
          .eq("conversation_id", conv.id)
          .order("seq")
          .limit(300)
      : { data: [] };

    const next = String(window ?? new Date().toISOString());
    return (
      <>
        {header}
        <TextThread
          clientId={id}
          clientName={detail.name}
          conversationId={conv?.id ?? null}
          messages={(thread ?? []) as never}
          scheduled={(scheduled ?? []) as never}
          templates={(templates ?? []) as never}
          canText={Boolean(consent?.can_text)}
          consentState={consent?.state ?? null}
          phone={consent?.consented_phone ?? consent?.client_phone ?? ""}
          canSend={canEdit}
          insideHours={new Date(next).getTime() <= Date.now() + 60_000}
          nextWindow={next}
        />
        <p className="lock" style={{ marginTop: 12 }}>
          Every text here is on the client&apos;s Activity as well, and goes into their file if their record is ever
          produced. Texts go out between 8am and 9pm, to the number they agreed to.
        </p>
      </>
    );
  }

  // ── Activity ───────────────────────────────────────────────
  if (tab === "activity") {
    // Thirty days by default, because a timeline that opens on two years of
    // history answers a question nobody asked.
    const days = /^[0-9]+$/.test(sp.days ?? "") ? Number(sp.days) : 30;
    const kind = ACTIVITY_KINDS.includes((sp.kind ?? "") as never) ? sp.kind! : null;

    let query = supabase
      .from("client_activity")
      .select("at, kind, title, detail, who, tab, ref_id")
      .eq("client_id", id)
      .order("at", { ascending: false })
      .limit(500);
    if (days > 0) {
      query = query.gte("at", new Date(Date.now() - days * 86400000).toISOString());
    }

    const [{ data: activity }, { data: taskRows }, { data: eventRows }, { data: mailRows }] = await Promise.all([
      query,
      supabase
        .from("tasks")
        .select("id, title, due, status, done_at, assigned_staff_id, system_generated")
        .eq("client_id", id)
        .eq("status", "Open")
        .order("due", { nullsFirst: false }),
      supabase
        .from("calendar_events")
        .select(
          "id, kind, title, starts_at, ends_at, location, origin, outlook_web_link, push_state, push_error, hours_prompt_answered_at, staff_id",
        )
        .eq("client_id", id)
        .order("starts_at", { ascending: false }),
      supabase
        .from("mail_log")
        .select("id, web_link, conversation_id")
        .eq("client_id", id)
        .order("sent_at", { ascending: false })
        .limit(500),
    ]);

    const all = (activity ?? []) as ActivityRow[];
    // Counted before the kind filter, so the chips say how much of each there
    // is rather than how much is currently showing.
    const counts = new Map<string, number>();
    for (const row of all) counts.set(row.kind, (counts.get(row.kind) ?? 0) + 1);

    const tasks: TaskRow[] = (taskRows ?? []).map((t) => ({
      id: t.id,
      title: t.title,
      due: t.due,
      status: t.status,
      done_at: t.done_at,
      system_generated: t.system_generated,
      assigned_name: t.assigned_staff_id ? (staffName.get(t.assigned_staff_id) ?? "") : "",
    }));
    const events = (eventRows ?? []) as EventRow[];

    return (
      <>
        {header}
        <ComingUp clientId={id} tasks={tasks} events={events} myId={me.id} now={new Date().toISOString()} />
        <ActivityTab
          clientId={id}
          clientName={detail.name}
          colleagues={staff.filter((s) => s.id !== me.id)}
          rows={kind ? all.filter((r) => r.kind === kind) : all}
          days={days}
          kind={kind}
          counts={counts}
          extras={{
            mail: Object.fromEntries(
              (mailRows ?? []).map((m) => [m.id, { web_link: m.web_link ?? "", conversation_id: m.conversation_id ?? "" }]),
            ),
            events: Object.fromEntries(events.map((e) => [e.id, { outlook_web_link: e.outlook_web_link }])),
          }}
        />
        {overlay}
      </>
    );
  }

  // ── Notes ──────────────────────────────────────────────────
  if (tab === "notes") {
    const [{ data }, { data: templateRows }] = await Promise.all([
      supabase
        .from("notes")
        .select("id, text, type, ts, at, staff_name, visible_roles, dated_from, attachment_id, from_ocr")
        .eq("client_id", id)
        .order("ts", { ascending: false }),
      // The headings each activity type starts with. Fetched with the notes
      // rather than on each dropdown change, so choosing a type is instant.
      supabase.from("note_templates").select("note_type, body").eq("active", true),
    ]);

    const templates = Object.fromEntries((templateRows ?? []).map((t) => [t.note_type, t.body]));

    // The file a note was made from. Read through RLS, so a restricted file
    // somebody may not see simply is not offered.
    const attachmentIds = (data ?? []).map((n) => n.attachment_id).filter((x): x is string => Boolean(x));
    const { data: noteFiles } = attachmentIds.length
      ? await supabase.from("attachments").select("id, storage_path, filename").in("id", attachmentIds)
      : { data: [] as { id: string; storage_path: string; filename: string }[] };
    const fileById = new Map((noteFiles ?? []).map((f) => [f.id, f]));
    const notes: NoteRow[] = (data ?? []).map((n) => ({
      ...n,
      file: n.attachment_id ? (fileById.get(n.attachment_id) ?? null) : null,
    }));

    return (
      <>
        {header}
        <NotesTab clientId={id} notes={notes} myName={me.name} templates={templates} />
        {overlay}
      </>
    );
  }

  // ── Jobs ───────────────────────────────────────────────────
  if (tab === "jobs") {
    const [{ data: jobs }, { data: employers }, { data: placements }] = await Promise.all([
      supabase
        .from("client_job_history")
        .select("*")
        .eq("client_id", id)
        .order("status_rank")
        .order("updated_at", { ascending: false }),
      supabase.from("employers").select("id, name").order("name"),
      supabase
        .from("placements")
        .select("id, employer, title, start_date, wage, hours_week, check30, check60, check90, jp_submitted, jp_paid, shifts_worked, fifth_shift_on, stability_on, stability_basis")
        .eq("client_id", id)
        .order("start_date", { ascending: false, nullsFirst: false }),
    ]);

    return (
      <>
        {header}
        {/* What we have tried, then what came of it: one timeline of the job search. */}
        <JobsPanel
          clientId={id}
          jobs={(jobs ?? []) as JobRow[]}
          employers={(employers ?? []) as { id: string; name: string }[]}
          canEdit={canEdit}
        />
        <h2 className="h2" style={{ margin: "22px 0 8px" }}>Placements</h2>
        <PlacementsTab clientId={id} placements={(placements ?? []) as PlacementRow[]} canEdit={canEdit} canBill={canBill} />
        {overlay}
      </>
    );
  }

  // ── Billing ────────────────────────────────────────────────
  if (tab === "billing") {
    const { data: auths } = await supabase
      .from("authorizations")
      .select(
        "id, number, service_type, total_hours, carried_used, rate_type, rate, start_date, end_date, status, requires_forms, dates_from_ocr",
      )
      .eq("client_id", id)
      .order("start_date", { ascending: false, nullsFirst: false });

    const authIds = (auths ?? []).map((a) => a.id);
    const idsOrNone = authIds.length ? authIds : ["00000000-0000-0000-0000-000000000000"];

    const [
      { data: entries },
      { data: clientFiles },
      { data: readings },
      { data: correctionRows },
      { data: invoiceRows },
      { data: paperworkRows },
      payments,
    ] = await Promise.all([
      supabase.from("service_entries").select("auth_id, hours, non_billable").in("auth_id", idsOrNone),
      // The PDFs: every file on this client's record, and what the inbox read
      // off the ones that came through it, so a file carrying one of these
      // authorizations' numbers can be offered first.
      supabase
        .from("attachments")
        .select("id, storage_path, filename, category, auth_id, created_at, review_note")
        .eq("client_id", id)
        .order("created_at", { ascending: false }),
      supabase.from("inbox_documents").select("storage_path, parsed, proposal").eq("client_id", id).eq("kind", "Authorization"),
      supabase
        .from("authorization_corrections")
        .select("auth_id, at, field, was_value, new_value, reason, staff_name")
        .in("auth_id", idsOrNone)
        .order("at"),
      supabase
        .from("invoices")
        .select("id, auth_id, number, date, amount, status, paid_date, warrant, service_type")
        .in("auth_id", idsOrNone)
        .order("date", { ascending: false }),
      supabase
        .from("client_paperwork")
        .select("auth_number, service_type, usor, form_name, month, state, form_id, hours_logged")
        .eq("client_id", id)
        .order("state")
        .order("usor"),
      readPayments(supabase, authIds),
    ]);

    const readingByPath = new Map(
      (readings ?? []).map((d) => {
        const proposal = (d.proposal ?? {}) as { candidates?: { id: string }[] };
        const fields = ((d.parsed ?? {}) as { fields?: Record<string, { value: string }> }).fields ?? {};
        return [
          d.storage_path,
          {
            authIds: new Set((proposal.candidates ?? []).map((c) => c.id)),
            start: fields.startDate?.value ?? "",
            end: fields.endDate?.value ?? "",
          },
        ] as const;
      }),
    );
    const unlinkedFiles = (clientFiles ?? []).filter((f) => !f.auth_id);

    // Received is invoices marked Paid; outstanding is invoices submitted to
    // USOR (Sent) and not yet paid. The owner's definitions, 14 Sept 2026.
    const invoices = (invoiceRows ?? []).map((i) => ({ ...i, amount: Number(i.amount) }));
    const received = invoices.filter((i) => i.status === "Paid").reduce((t, i) => t + i.amount, 0);
    const outstanding = invoices.filter((i) => i.status === "Sent").reduce((t, i) => t + i.amount, 0);
    const paidOn = new Map<string, string>();
    for (const i of invoices) {
      if (i.status !== "Paid" || !i.paid_date) continue;
      const seen = paidOn.get(i.auth_id);
      if (!seen || i.paid_date > seen) paidOn.set(i.auth_id, i.paid_date);
    }
    const pageByInvoice = new Map<string, string>();
    for (const p of payments) {
      if (p.invoice_id && p.page_id && !pageByInvoice.has(p.invoice_id)) pageByInvoice.set(p.invoice_id, p.page_id);
    }
    const authNumber = new Map((auths ?? []).map((a) => [a.id, a.number]));

    // Hours used = what was carried over at migration plus everything logged.
    const logged = new Map<string, number>();
    for (const e of entries ?? []) {
      if (e.non_billable) continue;
      logged.set(e.auth_id, (logged.get(e.auth_id) ?? 0) + Number(e.hours));
    }

    return (
      <>
        {header}

        <div className="card" style={{ marginBottom: 14 }}>
          <div className="row2" style={{ gap: 24, flexWrap: "wrap", alignItems: "baseline" }}>
            <div className="stat" style={{ fontSize: "var(--text-xl)" }}>
              {money(received)}
              <small>received · invoices marked Paid</small>
            </div>
            <div className="stat" style={{ fontSize: "var(--text-xl)", color: outstanding > 0 ? "var(--bad)" : undefined }}>
              {money(outstanding)}
              <small>outstanding · submitted, not yet paid</small>
            </div>
            {!canBill && (
              <span className="lock" style={{ marginLeft: "auto" }}>
                Read-only for your role. Admin and Billing act here.
              </span>
            )}
          </div>
        </div>

        {/*
          The authorizations as the one table, so they sort by number, service,
          status or dates. Each still carries its own files and payments, in
          its row.
        */}
        <h2 className="h2" style={{ margin: "0 0 8px" }}>Authorizations</h2>
        {(auths ?? []).length === 0 && <div className="empty">No authorizations on file. Add them from Billing.</div>}
        {(auths ?? []).length > 0 && (
        <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="authorizations"
          columns={[
            { key: "auth", label: "Authorization, its files and payments", sortLabel: "Number" },
            { key: "service", label: "Service" },
            { key: "status", label: "Status" },
            { key: "ends", label: "Ends" },
            { key: "left", label: "Hours left", align: "right" },
          ]}
          rows={(auths ?? []).map((a) => {
          const used = Number(a.carried_used ?? 0) + (logged.get(a.id) ?? 0);
          const total = a.total_hours ? Number(a.total_hours) : null;
          const remaining = total === null ? null : total - used;
          const pct = total ? Math.min(100, (used / total) * 100) : 0;
          const tone = remaining === null ? "" : remaining <= 0 ? "bad" : pct >= 90 ? "warn" : "";

          const body = (
            <div>
              <div className="row2" style={{ justifyContent: "space-between" }}>
                <b>{a.number || "(no authorization number)"}</b>
                <span className="chip gold">{a.service_type}</span>
              </div>
              <div style={{ fontSize: "var(--text-md)", marginTop: 6 }}>
                {a.rate_type === "Hourly" && total !== null
                  ? `${total} hrs @ ${money(a.rate)} · used ${used} · ${remaining} remaining`
                  : `Flat fee ${money(a.rate)}`}
              </div>
              {total !== null && (
                <div className="bar" style={{ marginTop: 6 }}>
                  <i className={tone} style={{ width: `${pct}%` }} />
                </div>
              )}
              <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)", marginTop: 6 }}>
                {a.start_date || "—"} → {a.end_date || "—"}
                {a.dates_from_ocr && " (read by OCR from the scan — check them)"} · {a.status}
                {a.requires_forms && ` · needs: ${a.requires_forms}`}
              </div>
              <AuthorizationFiles
                clientId={id}
                authId={a.id}
                authNumber={a.number}
                linked={(clientFiles ?? []).filter((f) => f.auth_id === a.id)}
                available={unlinkedFiles.map((f) => {
                  const reading = f.storage_path ? readingByPath.get(f.storage_path) : undefined;
                  return {
                    ...f,
                    suggested: Boolean(reading?.authIds.has(a.id)),
                    start: reading?.start ?? "",
                    end: reading?.end ?? "",
                  };
                })}
                canConfirm={canBill}
                paidOn={paidOn.get(a.id) ?? null}
                corrections={(correctionRows ?? []).filter((c) => c.auth_id === a.id)}
              />
              <AuthorizationPayments payments={payments.filter((p) => p.auth_id === a.id)} status={a.status} />
            </div>
          );
          return {
            key: a.id,
            sort: {
              auth: a.number,
              service: a.service_type,
              status: a.status,
              ends: a.end_date,
              left: remaining,
            },
            text: [a.number, a.service_type, a.status, a.start_date, a.end_date].filter(Boolean).join(" "),
            cells: {
              auth: body,
              service: a.service_type,
              status: <span className={"chip " + (a.status === "Paid" ? "ok" : "")}>{a.status}</span>,
              ends: <span style={{ whiteSpace: "nowrap" }}>{a.end_date ?? "—"}</span>,
              left: remaining === null ? "—" : remaining,
            },
          };
        })}
          empty="No authorizations on file. Add them from Billing."
        />
        </div>
        )}

        <h2 className="h2" style={{ margin: "22px 0 8px" }}>Invoices</h2>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="invoices"
            columns={[
              { key: "date", label: "Date" },
              { key: "number", label: "Invoice" },
              { key: "service", label: "Service" },
              { key: "amount", label: "Amount", align: "right" },
              { key: "status", label: "Status" },
              { key: "warrant", label: "Warrant" },
            ]}
            rows={invoices.map((i) => ({
              key: i.id,
              sort: {
                date: i.date,
                number: i.number || authNumber.get(i.auth_id) || "",
                amount: i.amount,
                status: i.status,
                warrant: i.status === "Paid" ? (i.warrant ?? "") : "",
              },
              cells: {
                date: i.date,
                number: i.number || authNumber.get(i.auth_id) || "",
                service: i.service_type,
                amount: money(i.amount),
                status: (
                  <>
                    <span className={"chip " + (i.status === "Paid" ? "ok" : i.status === "Sent" ? "warn" : "")}>
                      {i.status}
                    </span>
                    {i.status === "Paid" && i.paid_date && <div className="lock">paid {i.paid_date}</div>}
                  </>
                ),
                warrant:
                  i.status === "Paid" ? (
                    <span style={{ fontSize: "var(--text-sm)" }}>
                      <WarrantLink payment={{ warrant_no: i.warrant ?? "", page_id: pageByInvoice.get(i.id) ?? null }} />
                    </span>
                  ) : (
                    "—"
                  ),
              },
            }))}
            empty="No invoices for this client."
          />
        </div>

        <div id="paperwork">
          <PaperworkStrip clientId={id} rows={(paperworkRows ?? []) as PaperworkRow[]} />
        </div>
        {overlay}
      </>
    );
  }

  // ── Documents ──────────────────────────────────────────────
  if (tab === "documents") {
    // Restricted documents are filtered out by RLS, not here — a staff member
    // without access does not learn that they exist.
    const [{ data: files }, { data: formRows }, { data: authRows }, { data: reportRows }] = await Promise.all([
      supabase
        .from("attachments")
        .select("id, storage_path, filename, mime_type, size_bytes, category, restricted, note, uploaded_by_name, created_at")
        .eq("client_id", id)
        .order("created_at", { ascending: false }),
      supabase
        .from("forms")
        .select("id, template_id, status, month, auth_id, created_at, completed_at, completed_by_name, sent_to")
        .eq("client_id", id)
        .order("created_at", { ascending: false }),
      supabase.from("authorizations").select("id, number, service_type, status").eq("client_id", id).order("number"),
      supabase
        .from("contact_log")
        .select("id, date, topic, outcome, staff_id")
        .eq("client_id", id)
        .eq("method", "Report sent")
        .order("date", { ascending: false })
        .limit(50),
    ]);

    const forms = (formRows ?? []) as FormRow[];
    const authsForForms = authRows ?? [];
    const authChoices: AuthChoice[] = authsForForms.map((a) => ({
      id: a.id,
      label: `${a.number || "(no number)"} · ${a.service_type}`,
      serviceType: a.service_type,
    }));
    // The same test the database applies before letting an invoice be sent,
    // shown here where the work to clear it actually happens.
    const missingForBilling = authsForForms
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

    const reports = reportRows ?? [];

    return (
      <>
        {header}

        <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start", gap: 12, marginBottom: 8 }}>
          <div>
            <h2 className="h2">Progress reports</h2>
            <p className="sub" style={{ margin: "4px 0 0" }}>
              Built from notes, hours, job search, placements and counselor contacts, and emailed to
              the counselor on the record.
            </p>
          </div>
          <Link className="btn" href={`/clients/${id}?tab=documents&report=Weekly`} style={{ textDecoration: "none" }}>
            Send report
          </Link>
        </div>
        <div className="card" style={{ marginBottom: 14, padding: 0 }}>
          <DataTable
            label="reports"
            columns={[
              { key: "date", label: "Date", width: 110 },
              { key: "topic", label: "Report" },
              { key: "staff", label: "Sent by" },
            ]}
            rows={reports.map((r) => {
              const by = r.staff_id ? (staffName.get(r.staff_id) ?? "") : "";
              return {
                key: r.id,
                sort: { date: r.date, topic: r.topic, staff: by },
                text: `${r.date} ${r.topic} ${r.outcome} ${by}`,
                cells: {
                  date: r.date,
                  topic: (
                    <>
                      {r.topic}
                      <div className="lock">{r.outcome}</div>
                    </>
                  ),
                  staff: <span className="lock">{by}</span>,
                },
              };
            })}
            empty="No report has been emailed for this client yet."
          />
        </div>

        <h2 className="h2" style={{ margin: "22px 0 8px" }}>USOR forms</h2>
        <FormsTab clientId={id} forms={forms} auths={authChoices} missingForBilling={missingForBilling} />

        <h2 className="h2" style={{ margin: "22px 0 8px" }}>Files</h2>
        <FilesTab clientId={id} files={(files ?? []) as AttachmentRow[]} canSeeRestricted={canSeeRestricted} />
        {overlay}
      </>
    );
  }

  // ── Profile ────────────────────────────────────────────────
  // Intake is opened on request rather than with the tab: reading it is written
  // to the access log, and a profile opened to check a phone number should not
  // record that somebody read the client's accommodations.
  const openIntake = canEdit && sp.intake === "1";
  const [
    privateResult,
    counselorsResult,
    officesResult,
    historyResult,
    paperworkResult,
    consentResult,
    textsResult,
    intakeResult,
  ] = await Promise.all([
    // Restricted details come through the function that writes the access
    // log. It returns an "allowed" flag rather than a null, so the panel can
    // still tell "we do not hold this" from "this is not for you".
    supabase.rpc("read_client_private", { p_client_id: id, p_purpose: "shown on the client record" }),
    supabase.from("counselors").select("id, name").order("name"),
    supabase.from("offices").select("name").order("name"),
    supabase.from("client_stage_history").select("stage, at").eq("client_id", id).order("at", { ascending: false }).limit(8),
    supabase.from("client_paperwork").select("state").eq("client_id", id),
    supabase
      .from("client_sms_consent")
      .select("state, consented_phone, client_phone, method, since, can_text")
      .eq("client_id", id)
      .maybeSingle(),
    supabase
      .from("sms_messages")
      .select("id, direction, body, kind, status, error, sent_at, created_at")
      .eq("client_id", id)
      .order("created_at", { ascending: false })
      .limit(8),
    openIntake
      ? supabase.rpc("read_client_intake", { p_client_id: id, p_purpose: "opened the intake record" })
      : Promise.resolve({ data: null }),
  ]);

  const restricted = (privateResult.data ?? [])[0] ?? null;
  const paperwork = paperworkResult.data ?? [];
  const blocking = paperwork.filter((p) => p.state === "Missing").length;
  const complete = paperwork.filter((p) => p.state === "Complete").length;
  const intake = openIntake ? ((((intakeResult.data ?? []) as unknown[])[0] ?? null) as IntakeRow | null) : null;

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
            staff={staff}
            offices={(officesResult.data ?? []).map((o) => o.name)}
            canEdit={canEdit}
            isAdmin={isAdmin}
          />
          <RestrictedPanel
            clientId={detail.id}
            dob={restricted?.dob ?? null}
            address={restricted?.address ?? ""}
            visible={canSeeRestricted}
            canEdit={canEdit}
          />
          {canEdit && (
            <div id="intake">
              {openIntake ? (
                <IntakeTab
                  clientId={id}
                  clientName={detail.name}
                  intake={intake}
                  visible={canSeeRestricted}
                  canEdit={canEdit}
                />
              ) : (
                <div className="card">
                  <h3>Intake</h3>
                  <p className="sub" style={{ marginTop: 0 }}>
                    Restricted: accommodations, emergency contact and address. Opening it is recorded
                    in the access log.
                  </p>
                  <Link className="btn ghost" href={`/clients/${id}?tab=profile&intake=1#intake`} style={{ textDecoration: "none" }}>
                    Open the intake record
                  </Link>
                </div>
              )}
            </div>
          )}
        </div>

        <div className="grid" style={{ alignContent: "start" }}>
          <StageControl client={detail} canEdit={canEdit} />

          <div className="card">
            <h3>Stage history</h3>
            <DataTable
              label="stage changes"
              columns={[
                { key: "stage", label: "Stage" },
                { key: "at", label: "When" },
              ]}
              rows={(historyResult.data ?? []).map((h, i) => ({
                key: `${h.at}-${i}`,
                sort: { at: h.at },
                cells: { stage: h.stage, at: <span style={{ color: "var(--muted)" }}>{h.at}</span> },
              }))}
              empty="No stage change has been recorded yet."
            />
          </div>

          {/* The paperwork itself lives on Billing, beside the authorizations it gates. */}
          <div className="card">
            <h3>Paperwork</h3>
            <p className="sub" style={{ margin: 0 }}>
              {paperwork.length === 0 ? (
                "No open authorization needs a USOR form yet."
              ) : (
                <>
                  {blocking > 0 ? <b style={{ color: "var(--bad)" }}>{blocking} blocking billing</b> : "Nothing blocking billing"}
                  {` · ${complete} of ${paperwork.length} complete · `}
                  <Link href={`/clients/${id}?tab=billing#paperwork`}>See it on Billing</Link>
                </>
              )}
            </p>
          </div>

          <TextingPanel
            clientId={id}
            clientName={detail.name}
            consent={(consentResult.data ?? null) as ConsentRow | null}
            texts={(textsResult.data ?? []) as TextRow[]}
            canEdit={canEdit}
          />
        </div>
      </div>
      {overlay}
    </>
  );
}
