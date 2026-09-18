import Link from "next/link";
import { NO_BILLING_OFFICE, type BillingOffice } from "@/lib/billing-offices";

/**
 * "Billing office: All · Downtown CRP · … · None", as links.
 *
 * A filter is .segmented, never a second row of tabs, and it lives in the
 * address so a filtered list can be bookmarked or sent to somebody. `href`
 * builds each link so every screen keeps its own other filters.
 */
export function BillingOfficeFilter({
  billingOffices,
  selected,
  href,
  showNone = true,
}: {
  billingOffices: BillingOffice[];
  selected: string | null;
  href: (bo: string | null) => string;
  showNone?: boolean;
}) {
  return (
    <div className="row2 no-print" style={{ alignItems: "center", gap: 8, marginBottom: 8 }}>
      <span className="lock">Billing office</span>
      <div className="segmented">
        <Link href={href(null)} className={selected ? undefined : "on"}>
          All
        </Link>
        {billingOffices.map((b) => (
          <Link key={b.id} href={href(b.id)} className={selected === b.id ? "on" : undefined}>
            {b.name}
          </Link>
        ))}
        {showNone && (
          <Link href={href(NO_BILLING_OFFICE)} className={selected === NO_BILLING_OFFICE ? "on" : undefined}>
            None
          </Link>
        )}
      </div>
    </div>
  );
}

/** Adds, replaces or removes ?bo= on a path that may already have a query. */
export function withBo(path: string, bo: string | null, hash = ""): string {
  const [base, query = ""] = path.split("?");
  const params = new URLSearchParams(query);
  if (bo) params.set("bo", bo);
  else params.delete("bo");
  const q = params.toString();
  return `${base}${q ? `?${q}` : ""}${hash}`;
}
