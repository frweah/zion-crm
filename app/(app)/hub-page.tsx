import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { navFor, NAV_GROUPS } from "@/lib/roles";
import { PageHead } from "./page-head";

/**
 * A hub: the feature cards it holds (Design language, §1).
 *
 * Connecteam opens each hub on a page of cards rather than dropping somebody
 * straight onto the first screen, and the reason is worth keeping: a person
 * who knows what they want clicks past it in a second, and a person who does
 * not can see everything the hub contains without opening six screens to find
 * out.
 *
 * The cards are the hub's own navigation entries, so a screen added to a hub
 * appears here without anybody remembering to add it - the same list the
 * sidebar and the tab strip read.
 */
export async function HubPage({ hub, lead }: { hub: string; lead: string }) {
  const me = await requireStaff();
  const group = NAV_GROUPS.find((g) => g.hub === hub);
  if (!group) notFound();

  const mine = navFor(me).find((n) => n.group.key === group.key);
  if (!mine || mine.items.length === 0) notFound();

  return (
    <>
      <PageHead title={group.label} context={lead} />
      <div className="hub-cards">
        {mine.items.map((item) => (
          <Link key={item.href} href={item.href} className="hub-card">
            <span className="hub-card-label">{item.label}</span>
            {item.note && <span className="hub-card-note">{item.note}</span>}
          </Link>
        ))}
      </div>
    </>
  );
}
