import Link from "next/link";
import { fmtStamp } from "@/lib/constants";
import { DataTable } from "../data-table";

/**
 * The directory's change log (0099), as people read it.
 *
 * The database writes every entry itself - a counselor, a billing office or an
 * office added, edited, moved or removed - with each field's before and after.
 * This only puts names on the fields and "blank" where there was nothing.
 */
export type DirectoryChange = {
  id: string;
  at: string;
  entity: string;
  entity_key: string;
  entity_name: string;
  action: string;
  changes: unknown;
  reason: string;
  changed_by_name: string;
};

export const DIRECTORY_CHANGE_COLUMNS =
  "id, at, entity, entity_key, entity_name, action, changes, reason, changed_by_name";

const LABELS: Record<string, string> = {
  name: "Name",
  agency: "Agency",
  office: "Office",
  phone: "Phone",
  fax: "Fax",
  email: "Email",
  notes: "Notes",
  note: "Note",
  address: "Address",
  billing_office_id: "Billing office",
  billing_email: "Billing address",
  has_group_address: "Group address",
  contact_name: "Contact",
  contact_title: "Contact's title",
  contact_email: "Contact's email",
};

type Diff = Record<string, { from: unknown; to: unknown }>;

function shown(v: unknown, billingNames: Map<string, string>, key: string): string {
  if (v === null || v === undefined || v === "") return "blank";
  if (typeof v === "boolean") return v ? "yes" : "no";
  if (key === "billing_office_id" && typeof v === "string") return billingNames.get(v) ?? "another billing office";
  return String(v);
}

/** One line per field that changed; for an addition or removal, what it held. */
export function describeChange(c: DirectoryChange, billingNames: Map<string, string>): string[] {
  const diff = (c.changes ?? {}) as Diff;
  const keys = Object.keys(diff).filter((k) => k !== "id" && LABELS[k]);
  if (c.action === "Added" || c.action === "Removed") {
    const side = c.action === "Added" ? "to" : "from";
    return keys
      .filter((k) => shown(diff[k][side], billingNames, k) !== "blank")
      .map((k) => `${LABELS[k]}: ${shown(diff[k][side], billingNames, k)}`);
  }
  return keys.map(
    (k) => `${LABELS[k]}: ${shown(diff[k].from, billingNames, k)} → ${shown(diff[k].to, billingNames, k)}`,
  );
}

export function DirectoryHistory({
  changes,
  billingNames,
  showWhat = true,
  empty,
}: {
  changes: DirectoryChange[];
  billingNames: Map<string, string>;
  showWhat?: boolean;
  empty: string;
}) {
  return (
    <DataTable
      label="changes"
      columns={[
        { key: "at", label: "When" },
        ...(showWhat ? [{ key: "what", label: "What" }] : []),
        { key: "action", label: "Change" },
        { key: "detail", label: "Detail" },
        { key: "by", label: "By" },
      ]}
      rows={changes.map((c) => {
        const lines = describeChange(c, billingNames);
        return {
          key: c.id,
          cells: {
            at: <span style={{ whiteSpace: "nowrap" }}>{fmtStamp(c.at)}</span>,
            what: (
              <>
                {c.entity === "Counselor" && c.action !== "Removed" ? (
                  <Link href={`/counselors/${c.entity_key}`} style={{ color: "var(--teal)" }}>
                    <b>{c.entity_name}</b>
                  </Link>
                ) : (
                  <b>{c.entity_name}</b>
                )}
                <div className="lock">{c.entity}</div>
              </>
            ),
            action: <span className={"chip" + (c.action === "Moved office" ? " warn" : "")}>{c.action}</span>,
            detail: (
              <>
                {lines.map((l, i) => (
                  <div key={i}>{l}</div>
                ))}
                {c.reason && <div className="lock">Why: {c.reason}</div>}
              </>
            ),
            by: c.changed_by_name,
          },
          sort: { at: c.at, what: c.entity_name, action: c.action, by: c.changed_by_name },
          text: `${c.entity_name} ${c.entity} ${c.action} ${lines.join(" ")} ${c.reason} ${c.changed_by_name}`,
        };
      })}
      empty={empty}
    />
  );
}
