/**
 * Sorting and filtering for the Clients list, and the saved views built on it.
 *
 * One shape serves three places: the URL (so a filtered list can be linked and
 * bookmarked), a saved view's stored JSON, and the query that runs. Keeping
 * them the same means a saved view is just a URL someone gave a name to.
 */

export const CLIENT_SORTS = [
  "name",
  "clientNo",
  "counselor",
  "office",
  "billingOffice",
  "stage",
  "assigned",
  "createdAt",
  "lastActivity",
  // The job-search board's columns (0117).
  "availability",
  "applied",
  "nextInterview",
] as const;
export type ClientSort = (typeof CLIENT_SORTS)[number];

export const CLIENT_SORT_LABELS: Record<ClientSort, string> = {
  name: "Client",
  clientNo: "#",
  counselor: "Counselor",
  office: "Office",
  billingOffice: "Billing office",
  stage: "Stage",
  assigned: "Assigned",
  createdAt: "Referred",
  lastActivity: "Last activity",
  availability: "Availability",
  applied: "Applied (7d)",
  nextInterview: "Next interview",
};

export type SortDir = "asc" | "desc";

export type ClientFilters = {
  q: string;
  status: string[];
  stage: string[];
  counselorId: string[];
  assignedStaffId: string[];
  fundingSource: string[];
  office: string[];
  /** A billing office's id, or "none". */
  billingOffice: string[];
  hasImportReview: boolean;
  /** Looking for work: an application still going, or one made in the last 30 days (0117). */
  jobSearch: boolean;
  /** Clients with an open authorization - what Billing works across (caseload summary). */
  openAuth: boolean;
  /** Referred on or after this date, "YYYY-MM-DD" - "new this month". */
  since: string;
  inactiveDays: number | null;
  sort: ClientSort;
  dir: SortDir;
};

export const EMPTY_FILTERS: ClientFilters = {
  q: "",
  status: [],
  stage: [],
  counselorId: [],
  assignedStaffId: [],
  fundingSource: [],
  office: [],
  billingOffice: [],
  hasImportReview: false,
  jobSearch: false,
  openAuth: false,
  since: "",
  inactiveDays: null,
  sort: "name",
  dir: "asc",
};

/**
 * Values arrive from two places with different shapes: a URL gives strings and
 * repeated strings, saved-view JSON gives real booleans and numbers. Both are
 * accepted, which is why everything here is read as unknown and narrowed.
 */
const asArray = (v: unknown): string[] =>
  v === undefined || v === null
    ? []
    : Array.isArray(v)
      ? v.map(String).filter(Boolean)
      : v
        ? [String(v)]
        : [];

const first = (v: unknown): unknown => (Array.isArray(v) ? v[0] : v);

export function parseFilters(raw: Record<string, unknown>): ClientFilters {
  const r = raw;
  const days = Number(first(r.inactiveDays));
  const sort = String(first(r.sort) ?? "name");
  const dir = String(first(r.dir) ?? "asc");
  const review = first(r.hasImportReview);
  const jobSearch = first(r.jobSearch);
  const openAuth = first(r.openAuth);
  const since = String(first(r.since) ?? "");

  return {
    q: String(first(r.q) ?? ""),
    status: asArray(r.status),
    stage: asArray(r.stage),
    counselorId: asArray(r.counselorId),
    assignedStaffId: asArray(r.assignedStaffId),
    fundingSource: asArray(r.fundingSource),
    office: asArray(r.office),
    billingOffice: asArray(r.billingOffice),
    hasImportReview: review === true || review === "true" || review === "on",
    jobSearch: jobSearch === true || jobSearch === "true" || jobSearch === "on",
    openAuth: openAuth === true || openAuth === "true" || openAuth === "on",
    since: /^\d{4}-\d{2}-\d{2}$/.test(since) ? since : "",
    inactiveDays: Number.isFinite(days) && days > 0 ? days : null,
    sort: (CLIENT_SORTS as readonly string[]).includes(sort) ? (sort as ClientSort) : "name",
    dir: dir === "desc" ? "desc" : "asc",
  };
}

/** Back to a query string — empty values omitted, so URLs stay readable. */
export function toQuery(f: ClientFilters): string {
  const p = new URLSearchParams();
  if (f.q) p.set("q", f.q);
  for (const k of ["status", "stage", "counselorId", "assignedStaffId", "fundingSource", "office", "billingOffice"] as const) {
    for (const v of f[k]) p.append(k, v);
  }
  if (f.hasImportReview) p.set("hasImportReview", "true");
  if (f.jobSearch) p.set("jobSearch", "true");
  if (f.openAuth) p.set("openAuth", "true");
  if (f.since) p.set("since", f.since);
  if (f.inactiveDays) p.set("inactiveDays", String(f.inactiveDays));
  if (f.sort !== "name") p.set("sort", f.sort);
  if (f.dir !== "asc") p.set("dir", f.dir);
  return p.toString();
}

/** What a saved view stores. Same shape, minus the defaults. */
export function toParams(f: ClientFilters): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (f.q) out.q = f.q;
  for (const k of ["status", "stage", "counselorId", "assignedStaffId", "fundingSource", "office", "billingOffice"] as const) {
    if (f[k].length) out[k] = f[k];
  }
  if (f.hasImportReview) out.hasImportReview = true;
  if (f.jobSearch) out.jobSearch = true;
  if (f.openAuth) out.openAuth = true;
  if (f.since) out.since = f.since;
  if (f.inactiveDays) out.inactiveDays = f.inactiveDays;
  out.sort = f.sort;
  out.dir = f.dir;
  return out;
}

export function isFiltered(f: ClientFilters): boolean {
  return Boolean(
    f.q ||
      f.status.length ||
      f.stage.length ||
      f.counselorId.length ||
      f.assignedStaffId.length ||
      f.fundingSource.length ||
      f.office.length ||
      f.billingOffice.length ||
      f.hasImportReview ||
      f.jobSearch ||
      f.openAuth ||
      f.since ||
      f.inactiveDays,
  );
}

/** Header link target: clicking the active column reverses it. */
export function sortLink(f: ClientFilters, column: ClientSort, base = "/clients"): string {
  const next: ClientFilters = {
    ...f,
    sort: column,
    dir: f.sort === column && f.dir === "asc" ? "desc" : "asc",
  };
  const q = toQuery(next);
  return q ? `${base}?${q}` : base;
}
