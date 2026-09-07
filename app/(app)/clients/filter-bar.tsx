import { CLIENT_STATUSES, STAGES, FUNDING_SOURCES } from "@/lib/constants";
import type { ClientFilters } from "@/lib/list-filters";

type Option = { id: string; name: string };

/**
 * A plain GET form.
 *
 * Submitting builds the query string the list already reads, so filtering
 * needs no JavaScript, every filtered list is a shareable URL, and the back
 * button behaves. Checkboxes with a repeated name give the arrays directly.
 */
export function FilterBar({
  filters,
  counselors,
  staff,
  offices,
  fundingSources,
  resultCount,
  totalCount,
}: {
  filters: ClientFilters;
  counselors: Option[];
  staff: Option[];
  offices: string[];
  fundingSources: string[];
  resultCount: number;
  totalCount: number;
}) {
  return (
    <form method="get" action="/clients" className="card" style={{ marginBottom: 14 }}>
      {/* Sort travels with the filters so changing one does not reset the other. */}
      <input type="hidden" name="sort" value={filters.sort} />
      <input type="hidden" name="dir" value={filters.dir} />

      <div className="row2">
        <label className="field" style={{ flex: 2 }}>
          Search
          <input
            name="q"
            defaultValue={filters.q}
            placeholder="Name, client #, agency ID, or counselor"
          />
        </label>

        <label className="field">
          Counselor
          <select name="counselorId" defaultValue={filters.counselorId[0] ?? ""}>
            <option value="">Any</option>
            {counselors.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>

        <label className="field">
          Assigned to
          <select name="assignedStaffId" defaultValue={filters.assignedStaffId[0] ?? ""}>
            <option value="">Anyone</option>
            {staff.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </label>

        <label className="field">
          Office
          <select name="office" defaultValue={filters.office[0] ?? ""}>
            <option value="">Any</option>
            {offices.map((o) => (
              <option key={o}>{o}</option>
            ))}
          </select>
        </label>

        <label className="field">
          Funding
          <select name="fundingSource" defaultValue={filters.fundingSource[0] ?? ""}>
            <option value="">Any</option>
            {(fundingSources.length ? fundingSources : [...FUNDING_SOURCES]).map((f) => (
              <option key={f}>{f}</option>
            ))}
          </select>
        </label>
      </div>

      <div className="row2" style={{ marginTop: 12, alignItems: "flex-start" }}>
        <div className="field" style={{ marginBottom: 0 }}>
          Status
          <div style={{ display: "flex", gap: 10, marginTop: 6, flexWrap: "wrap" }}>
            {CLIENT_STATUSES.map((s) => (
              <label key={s} style={{ fontSize: 13, color: "var(--ink)" }}>
                <input
                  type="checkbox"
                  name="status"
                  value={s}
                  defaultChecked={filters.status.includes(s)}
                  style={{ width: "auto", marginRight: 5 }}
                />
                {s}
              </label>
            ))}
          </div>
        </div>

        <div className="field" style={{ marginBottom: 0, flex: 2 }}>
          Stage
          <div style={{ display: "flex", gap: 10, marginTop: 6, flexWrap: "wrap" }}>
            {STAGES.map((s) => (
              <label key={s} style={{ fontSize: 13, color: "var(--ink)" }}>
                <input
                  type="checkbox"
                  name="stage"
                  value={s}
                  defaultChecked={filters.stage.includes(s)}
                  style={{ width: "auto", marginRight: 5 }}
                />
                {s}
              </label>
            ))}
          </div>
        </div>
      </div>

      <div className="row2" style={{ marginTop: 12, alignItems: "center" }}>
        <label style={{ fontSize: 13 }}>
          <input
            type="checkbox"
            name="hasImportReview"
            defaultChecked={filters.hasImportReview}
            style={{ width: "auto", marginRight: 6 }}
          />
          Flagged for review
        </label>

        <label className="field" style={{ maxWidth: 210, marginBottom: 0 }}>
          No activity in (days)
          <input
            name="inactiveDays"
            type="number"
            min="1"
            placeholder="any"
            defaultValue={filters.inactiveDays ?? ""}
          />
        </label>

        <button className="btn" type="submit">
          Apply
        </button>
        <a className="btn ghost" href="/clients" style={{ textDecoration: "none" }}>
          Clear
        </a>

        <span className="lock" style={{ marginLeft: "auto" }}>
          {resultCount} of {totalCount} clients
        </span>
      </div>
    </form>
  );
}
