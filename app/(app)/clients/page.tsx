import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { CAN_EDIT_CLIENTS, daysBetween, today } from "@/lib/constants";
import {
  parseFilters,
  toQuery,
  sortLink,
  isFiltered,
  CLIENT_SORTS,
  CLIENT_SORT_LABELS,
  type ClientSort,
} from "@/lib/list-filters";
import { PageHead } from "../page-head";
import { DataTable } from "../data-table";
import { AddClientPanel } from "./clients-view";
import { FilterBar } from "./filter-bar";
import { readBillingOffices, matchesBo } from "@/lib/billing-offices";
import { SavedViews, type SavedView } from "./saved-views";
import { loadCaseload } from "@/lib/caseload";
import { CaseloadSummary } from "../caseload-summary";

type Row = {
  id: string;
  name: string;
  client_no: number | null;
  stage: string;
  status: string;
  agency_id: string;
  referring_office: string;
  billing_office: string;
  import_review: string;
  funding_source: string;
  created_at: string;
  counselor_name: string;
  assigned_name: string;
  last_activity: string | null;
  schedule: string;
  preferred_locations: string;
  applied7: number;
  next_interview: string | null;
  searching: boolean;
};

export default async function ClientsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const me = await requireStaff();
  const raw = await searchParams;
  const filters = parseFilters(raw);
  const activeViewId = typeof raw.view === "string" ? raw.view : null;

  const supabase = await createClient();

  // Filters that the database can apply are applied there. The rest — name
  // sorting by counselor, quiet-since — need joined values, and at this
  // caseload it is cheaper and far clearer to finish the job in memory than to
  // build a view for every combination.
  let query = supabase
    .from("clients")
    .select(
      "id, name, client_no, stage, status, agency_id, referring_office, import_review, funding_source, created_at, counselor_id, assigned_staff_id, schedule, preferred_locations",
    );

  if (filters.status.length) query = query.in("status", filters.status);
  if (filters.stage.length) query = query.in("stage", filters.stage);
  if (filters.counselorId.length) query = query.in("counselor_id", filters.counselorId);
  if (filters.assignedStaffId.length)
    query = query.in("assigned_staff_id", filters.assignedStaffId);
  if (filters.fundingSource.length) query = query.in("funding_source", filters.fundingSource);
  if (filters.office.length) query = query.in("referring_office", filters.office);
  if (filters.hasImportReview) query = query.neq("import_review", "");
  if (filters.since) query = query.gte("created_at", filters.since);

  const [billing, clientsResult, counselorsResult, staffResult, officesResult, activityResult, viewsResult, totalResult, prefResult, jobsResult] =
    await Promise.all([
      readBillingOffices(supabase),
      query,
      supabase.from("counselors").select("id, name").order("name"),
      supabase.from("staff").select("id, name").eq("active", true).eq("is_system", false).order("name"),
      supabase.from("offices").select("name").order("name"),
      supabase.from("client_last_activity").select("client_id, last_activity_at"),
      supabase
        .from("saved_views")
        .select("id, name, owner_staff_id")
        .eq("screen", "clients")
        .order("sort_order")
        .order("name"),
      supabase.from("clients").select("*", { count: "exact", head: true }),
      supabase
        .from("staff_prefs")
        .select("value")
        .eq("staff_id", me.id)
        .eq("key", "last_view:clients")
        .maybeSingle(),
      // The job search, per client: applications and interviews (0117).
      supabase.from("lead_matches").select("client_id, status, applied_on, interview_on, interview_result"),
    ]);

  // What the job-search board showed, worked out from the applications.
  const todayIso = today();
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);
  const monthAgo = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  const search = new Map<string, { applied7: number; next: string | null; searching: boolean }>();
  for (const m of jobsResult.data ?? []) {
    const s = search.get(m.client_id) ?? { applied7: 0, next: null, searching: false };
    if (m.applied_on && m.applied_on >= weekAgo) s.applied7++;
    const live = !["Hired", "Not selected", "Withdrawn"].includes(m.status);
    if (live || (m.applied_on && m.applied_on >= monthAgo)) s.searching = true;
    if (m.interview_on && m.interview_on >= todayIso && !["Cancelled", "Backed out", "Unscheduled"].includes(m.interview_result) && (!s.next || m.interview_on < s.next)) {
      s.next = m.interview_on;
    }
    search.set(m.client_id, s);
  }

  const counselors = counselorsResult.data ?? [];
  const staff = staffResult.data ?? [];
  const counselorName = new Map(counselors.map((c) => [c.id, c.name]));
  const staffName = new Map(staff.map((s) => [s.id, s.name]));
  const activity = new Map(
    (activityResult.data ?? []).map((a) => [a.client_id, a.last_activity_at]),
  );

  let rows: Row[] = (clientsResult.data ?? []).map((c) => ({
    id: c.id,
    name: c.name,
    client_no: c.client_no,
    stage: c.stage,
    status: c.status,
    agency_id: c.agency_id,
    referring_office: c.referring_office,
    billing_office: billing.forClient(c.id)?.name ?? "",
    import_review: c.import_review,
    funding_source: c.funding_source,
    created_at: c.created_at,
    counselor_name: c.counselor_id ? (counselorName.get(c.counselor_id) ?? "") : "",
    assigned_name: c.assigned_staff_id ? (staffName.get(c.assigned_staff_id) ?? "") : "",
    last_activity: activity.get(c.id) ?? null,
    schedule: c.schedule ?? "",
    preferred_locations: c.preferred_locations ?? "",
    applied7: search.get(c.id)?.applied7 ?? 0,
    next_interview: search.get(c.id)?.next ?? null,
    searching: search.get(c.id)?.searching ?? false,
  }));

  if (filters.jobSearch) rows = rows.filter((r) => r.searching);
  if (filters.openAuth) {
    const { data: open } = await supabase.from("authorizations").select("client_id").eq("status", "Open");
    const withOpen = new Set((open ?? []).map((a) => a.client_id));
    rows = rows.filter((r) => withOpen.has(r.id));
  }

  // Free-text search spans the fields someone would actually search by.
  if (filters.q) {
    const needle = filters.q.toLowerCase();
    rows = rows.filter(
      (r) =>
        r.name.toLowerCase().includes(needle) ||
        r.agency_id.toLowerCase().includes(needle) ||
        String(r.client_no ?? "").includes(needle) ||
        r.counselor_name.toLowerCase().includes(needle),
    );
  }

  if (filters.inactiveDays) {
    const cutoff = filters.inactiveDays;
    rows = rows.filter((r) => {
      if (!r.last_activity) return true;
      return daysBetween(r.last_activity.slice(0, 10), today()) >= cutoff;
    });
  }

  // Through the counselor's office, else the referring office (0091).
  if (filters.billingOffice.length) {
    rows = rows.filter((r) => filters.billingOffice.some((b) => matchesBo(b, billing.forClient(r.id))));
  }

  const dir = filters.dir === "desc" ? -1 : 1;
  const key = (r: Row): string | number => {
    switch (filters.sort) {
      case "clientNo": return r.client_no ?? Number.MAX_SAFE_INTEGER;
      case "counselor": return r.counselor_name.toLowerCase();
      case "office": return r.referring_office.toLowerCase();
      case "billingOffice": return r.billing_office.toLowerCase();
      case "stage": return r.stage.toLowerCase();
      case "assigned": return r.assigned_name.toLowerCase();
      case "createdAt": return r.created_at;
      case "lastActivity": return r.last_activity ?? "";
      case "availability": return r.schedule.toLowerCase();
      case "applied": return r.applied7;
      case "nextInterview": return r.next_interview ?? "9999";
      default: return r.name.toLowerCase();
    }
  };
  rows.sort((a, b) => {
    const ka = key(a), kb = key(b);
    if (ka === kb) return a.name.localeCompare(b.name);
    return (typeof ka === "number" && typeof kb === "number"
      ? ka - kb
      : String(ka).localeCompare(String(kb))) * dir;
  });

  const savedViews: SavedView[] = (viewsResult.data ?? []).map((v) => ({
    id: v.id,
    name: v.name,
    shared: v.owner_staff_id === null,
    mine: v.owner_staff_id === me.id,
  }));

  // The view someone had open last, when they have not asked for anything else.
  const remembered = prefResult.data?.value;
  const rememberedId = typeof remembered === "string" ? remembered : null;
  const currentView = activeViewId ?? (isFiltered(filters) ? null : rememberedId);

  const canEdit = CAN_EDIT_CLIENTS.includes(me.role);
  const query_ = toQuery(filters);
  const flagged = rows.filter((r) => r.import_review).length;

  /*
   * The sort in the address is the one a saved view remembers, so it stays a
   * choice of its own above the list. The table's headings sort what is on the
   * screen without touching the address.
   */
  const sortChoice = (col: ClientSort) => {
    const active = filters.sort === col;
    return (
      <Link key={col} href={sortLink(filters, col)} className={active ? "on" : ""}>
        {CLIENT_SORT_LABELS[col]}
        {active && (filters.dir === "asc" ? " ↑" : " ↓")}
      </Link>
    );
  };

  const lastActivityDays = (r: Row) =>
    r.last_activity ? daysBetween(r.last_activity.slice(0, 10), today()) : null;

  const columns = CLIENT_SORTS.map((col) => ({ key: col, label: CLIENT_SORT_LABELS[col] }));

  const tableRows = rows.map((c) => {
    const d = lastActivityDays(c);
    return {
      key: c.id,
      text: [c.name, c.client_no, c.agency_id, c.counselor_name, c.referring_office, c.billing_office, c.stage, c.assigned_name]
        .filter(Boolean)
        .join(" "),
      sort: {
        name: c.name.toLowerCase(),
        clientNo: c.client_no,
        counselor: c.counselor_name,
        office: c.referring_office,
        billingOffice: c.billing_office,
        stage: c.stage,
        assigned: c.assigned_name,
        createdAt: c.created_at,
        lastActivity: c.last_activity,
        availability: c.schedule,
        applied: c.applied7,
        nextInterview: c.next_interview,
      },
      cells: {
        name: (
          <>
            <Link href={`/clients/${c.id}`} style={{ color: "inherit", fontWeight: 600 }}>
              {c.name}
            </Link>
            {c.status !== "Active" && (
              <span className="chip" style={{ marginLeft: 6 }}>
                {c.status}
              </span>
            )}
            {c.import_review && (
              <span className="chip warn" style={{ marginLeft: 6 }} title={c.import_review}>
                review
              </span>
            )}
          </>
        ),
        clientNo: c.client_no ?? "",
        counselor: c.counselor_name,
        office: c.referring_office,
        billingOffice: c.billing_office || <span className="lock">None</span>,
        stage: <span className="chip gold">{c.stage}</span>,
        assigned: c.assigned_name || "—",
        createdAt: <span style={{ whiteSpace: "nowrap" }}>{c.created_at}</span>,
        lastActivity:
          d === null ? (
            "—"
          ) : (
            <span className={"chip " + (d >= 60 ? "warn" : "")} style={{ whiteSpace: "nowrap" }}>
              {d === 0 ? "today" : `${d}d ago`}
            </span>
          ),
        availability: (
          <>
            {c.schedule || "—"}
            {c.preferred_locations && <div className="lock">{c.preferred_locations}</div>}
          </>
        ),
        applied: c.applied7 || <span className="lock">0</span>,
        nextInterview: c.next_interview ? (
          <span className="chip warn" style={{ whiteSpace: "nowrap" }}>{c.next_interview}</span>
        ) : (
          <span className="lock">—</span>
        ),
      },
    };
  });

  return (
    <>
      <PageHead
        title="Clients"
        context={
          <>
            {me.role === "Reports"
              ? "All clients — complete intake from the client record"
              : "All clients"}
            {flagged > 0 && ` · ${flagged} flagged for review in this list`}
          </>
        }
      />

      {/* The counts in sight while moving through the list (21 Sept 2026). */}
      <CaseloadSummary caseload={await loadCaseload(supabase, me)} slim />

      <SavedViews
        screen="clients"
        views={savedViews}
        activeId={currentView}
        query={query_}
        isAdmin={me.role === "Admin"}
        canSave={isFiltered(filters)}
      />

      <FilterBar
        filters={filters}
        counselors={counselors}
        staff={staff}
        offices={(officesResult.data ?? []).map((o) => o.name)}
        billingOffices={billing.billingOffices.map((b) => ({ id: b.id, name: b.name }))}
        fundingSources={[...new Set(rows.map((r) => r.funding_source).filter(Boolean))]}
        resultCount={rows.length}
        totalCount={totalResult.count ?? 0}
      />

      {canEdit && (
        <AddClientPanel
          counselors={counselors}
          staff={staff}
          offices={(officesResult.data ?? []).map((o) => o.name)}
        />
      )}

      <div className="row2 no-print" style={{ alignItems: "center", gap: 8, marginBottom: 8 }}>
        <span className="lock">Sort by</span>
        <div className="segmented">{CLIENT_SORTS.map(sortChoice)}</div>
      </div>

      {/* The filter bar above already searches this list, so the table does not add a second box. */}
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="clients"
          filter={false}
          pageSize={50}
          columns={columns}
          rows={tableRows}
          empty={isFiltered(filters) ? "No clients match these filters." : "No clients yet."}
        />
      </div>
    </>
  );
}
