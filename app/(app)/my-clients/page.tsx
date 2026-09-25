import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PageHead } from "../page-head";

/**
 * My clients today.
 *
 * Where Job Search and Intake & Client Reports start the day: their own
 * caseload, with what is due against each person, in the order it matters.
 * The dashboard answers "what is happening in the practice"; this answers
 * "who am I seeing and what do they need", which is the question somebody
 * with a caseload actually has at nine in the morning.
 *
 * Everything shown is the same client_next_actions the record's own strip
 * reads, so the list and the record cannot disagree.
 */
type Due = { kind: string; title: string; detail: string; href: string; urgency: number };

export default async function MyClientsPage() {
  const me = await requireStaff();
  const supabase = await createClient();

  // Admin sees everybody's, as they do everywhere else; everyone else sees
  // the clients they are responsible for.
  const mine = me.role !== "Admin";
  let q = supabase
    .from("clients")
    .select("id, name, client_no, stage, assigned_staff_id, billing_staff_id")
    .eq("status", "Active")
    .order("name");
  // Either of a client's two people counts as theirs (0121).
  if (mine) q = q.or(`assigned_staff_id.eq.${me.id},billing_staff_id.eq.${me.id}`);
  const { data: clients } = await q;

  const list = clients ?? [];
  const due = await Promise.all(
    list.map(async (c) => {
      const { data } = await supabase.rpc("client_next_actions", { p_client: c.id });
      return { client: c, items: (data ?? []) as Due[] };
    }),
  );

  // Somebody with something due, most pressing first; then the rest, so the
  // caseload is all here and the page is not two screens.
  const needing = due
    .filter((d) => d.items.length > 0)
    .sort((a, b) => (a.items[0]?.urgency ?? 9) - (b.items[0]?.urgency ?? 9));
  const clear = due.filter((d) => d.items.length === 0);

  return (
    <>
      <PageHead
        title="My clients today"
        context={
          mine
            ? `${list.length} active on your caseload · ${needing.length} with something due`
            : `${list.length} active clients · ${needing.length} with something due`
        }
      />

      {list.length === 0 && (
        <div className="card">
          <p className="empty" style={{ margin: 0 }}>
            No active clients are assigned to you. <Link href="/clients">Everybody</Link> is on Clients.
          </p>
        </div>
      )}

      {needing.map(({ client, items }) => (
        <section key={client.id} className="card" style={{ marginBottom: 12 }}>
          <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
            <h2 className="h2" style={{ margin: 0, fontSize: "var(--text-xl)" }}>
              <Link href={`/clients/${client.id}`}>{client.name}</Link>
            </h2>
            <span className="lock">
              {client.client_no ? `#${client.client_no} · ` : ""}
              {client.stage}
            </span>
          </div>
          <ul className="next-strip" aria-label={`What is next for ${client.name}`}>
            {items.map((item, i) => (
              <li key={`${item.kind}-${i}`} className={item.urgency <= 1 ? "soon" : undefined}>
                <Link href={item.href}>
                  <b>{item.title}</b>
                  {item.detail && <span className="next-detail">{item.detail}</span>}
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ))}

      {clear.length > 0 && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Nothing due</h3>
          <p className="sub" style={{ marginTop: 0 }}>
            {clear.length} of your clients have no appointment booked, no form holding up billing and nothing
            unanswered.
          </p>
          <ul className="quiet-list">
            {clear.map(({ client }) => (
              <li key={client.id}>
                <Link href={`/clients/${client.id}`}>{client.name}</Link>
                <span className="lock"> {client.stage}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  );
}
