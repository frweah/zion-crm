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
import { AddClientPanel } from "./clients-view";
import { FilterBar } from "./filter-bar";
import { SavedViews, type SavedView } from "./saved-views";

type Row = {
  id: string;
  name: string;
  client_no: number | null;
  stage: string;
  status: string;
  agency_id: string;
  referring_office: string;
  import_review: string;
  funding_source: string;
  created_at: string;
  counselor_name: string;
  assigned_name: string;
  last_activity: string | null;
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
      "id, name, client_no, stage, status, agency_id, referring_office, import_review, funding_source, created_at, counselor_id, assigned_staff_id",
    );

  if (filters.status.length) query = query.in("status", filters.status);
  if (filters.stage.length) query = query.in("stage", filters.stage);
  if (filters.counselorId.length) query = query.in("counselor_id", filters.counselorId);
  if (filters.assignedStaffId.length)
    query = query.in("assigned_staff_id", filters.assignedStaffId);
  if (filters.fundingSource.length) query = query.in("funding_source", filters.fundingSource);
  if (filters.office.length) query = query.in("referring_office", filters.office);
  if (filters.hasImportReview) query = query.neq("import_review", "");

  const [clientsResult, counselorsResult, staffResult, officesResult, activityResult, viewsResult, totalResult, prefResult] =
    await Promise.all([
      query,
      supabase.from("counselors").select("id, name").order("name"),
      supabase.from("staff").select("id, name").eq("active", true).order("name"),
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
    ]);

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
    import_review: c.import_review,
    funding_source: c.funding_source,
    created_at: c.created_at,
    counselor_name: c.counselor_id ? (counselorName.get(c.counselor_id) ?? "") : "",
    assigned_name: c.assigned_staff_id ? (staffName.get(c.assigned_staff_id) ?? "") : "",
    last_activity: activity.get(c.id) ?? null,
  }));

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

  const dir = filters.dir === "desc" ? -1 : 1;
  const key = (r: Row): string | number => {
    switch (filters.sort) {
      case "clientNo": return r.client_no ?? Number.MAX_SAFE_INTEGER;
      case "counselor": return r.counselor_name.toLowerCase();
      case "office": return r.referring_office.toLowerCase();
      case "stage": return r.stage.toLowerCase();
      case "assigned": return r.assigned_name.toLowerCase();
      case "createdAt": return r.created_at;
      case "lastActivity": return r.last_activity ?? "";
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

  const header = (col: ClientSort) => {
    const active = filters.sort === col;
    return (
      <th key={col} style={{ whiteSpace: "nowrap" }}>
        <Link
          href={sortLink(filters, col)}
          style={{ color: active ? "var(--forest)" : "inherit", textDecoration: "none" }}
        >
          {CLIENT_SORT_LABELS[col]}
          {active && <span style={{ marginLeft: 4 }}>{filters.dir === "asc" ? "▲" : "▼"}</span>}
        </Link>
      </th>
    );
  };

  return (
    <>
      <h1 className="h1">Clients</h1>
      <p className="sub">
        {me.role === "Reports"
          ? "All clients — complete intake from the client record"
          : "All clients"}
        {flagged > 0 && ` · ${flagged} flagged for review in this list`}
      </p>

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

      <div className="card" style={{ padding: 0 }}>
        <table className="t">
          <thead>
            <tr>{CLIENT_SORTS.map(header)}</tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td colSpan={CLIENT_SORTS.length} className="empty">
                  {isFiltered(filters)
                    ? "No clients match these filters."
                    : "No clients yet."}
                </td>
              </tr>
            )}
            {rows.map((c) => (
              <tr key={c.id} className="row">
                <td>
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
                </td>
                <td>{c.client_no ?? ""}</td>
                <td>{c.counselor_name}</td>
                <td>{c.referring_office}</td>
                <td>
                  <span className="chip gold">{c.stage}</span>
                </td>
                <td>{c.assigned_name || "—"}</td>
                <td style={{ whiteSpace: "nowrap" }}>{c.created_at}</td>
                <td style={{ whiteSpace: "nowrap" }}>
                  {c.last_activity ? (
                    (() => {
                      const d = daysBetween(c.last_activity.slice(0, 10), today());
                      return (
                        <span className={"chip " + (d >= 60 ? "warn" : "")}>
                          {d === 0 ? "today" : `${d}d ago`}
                        </span>
                      );
                    })()
                  ) : (
                    "—"
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
