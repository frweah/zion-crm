import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { navFor, moreGroups } from "@/lib/roles";
import { PageHead } from "../page-head";

/**
 * More, on a phone (inventory, 11 Nov 2026).
 *
 * The bar holds Home, Clients, My work and Communication. Everything else
 * this person has is here, under the name of its group - Billing, HR, Admin,
 * whichever of them they have - so nothing they can open on a desk is out of
 * reach on a phone. It is the same list the sidebar draws, through the same
 * function the bar uses to decide what is not on it (lib/roles.ts
 * moreGroups), so the two cannot disagree.
 */
export default async function MorePage() {
  const me = await requireStaff();
  const groups = moreGroups(navFor(me));

  return (
    <>
      <PageHead title="More" />
      {groups.length === 0 ? (
        <p className="empty">Everything you have is on the bar below.</p>
      ) : (
        groups.map(({ group, items }) => (
          <section key={group.key} className="page-section">
            <h2 className="h2">{group.label}</h2>
            <div className="hub-cards">
              {items.map((item) => (
                <Link key={item.href} href={item.href} className="hub-card">
                  <span className="hub-card-label">{item.label}</span>
                  {item.note && <span className="hub-card-note">{item.note}</span>}
                </Link>
              ))}
            </div>
          </section>
        ))
      )}
    </>
  );
}
