import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/constants";

/**
 * The client, beside the thread (Design language, §2).
 *
 * Answering a text means knowing who is asking: their stage, who works with
 * them, what is open, what is due. That used to be a trip to their record and
 * back, and the thing somebody loses on that trip is the half-written reply.
 *
 * It is deliberately short - stage, people, what is next, and the way in.
 * The record is one click away and holds everything; this holds what somebody
 * needs in order to type the next sentence.
 */
export async function ClientCard({ clientId }: { clientId: string }) {
  const supabase = await createClient();

  const [{ data: client }, { data: next }] = await Promise.all([
    supabase
      .from("clients")
      .select("id, name, client_no, stage, status, assigned_staff_id, billing_staff_id, counselor_id, phone")
      .eq("id", clientId)
      .maybeSingle(),
    supabase.rpc("client_next_actions", { p_client: clientId }),
  ]);
  if (!client) return null;

  const [{ data: staff }, { data: counselor }] = await Promise.all([
    supabase
      .from("staff")
      .select("id, name")
      .in("id", [client.assigned_staff_id, client.billing_staff_id].filter((v): v is string => Boolean(v))),
    client.counselor_id
      ? supabase.from("counselors").select("name, office").eq("id", client.counselor_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const nameOf = new Map((staff ?? []).map((s) => [s.id, s.name]));
  const actions = ((next ?? []) as { title: string; detail: string }[]).slice(0, 3);

  return (
    <aside className="thread-aside">
      <div className="card">
        <h3 style={{ marginTop: 0 }}>
          <Link href={`/clients/${client.id}`}>{client.name}</Link>
        </h3>
        <p className="lock" style={{ marginTop: 0 }}>
          {[client.client_no ? `Client ${client.client_no}` : null, client.stage, client.status]
            .filter(Boolean)
            .join(" · ")}
        </p>

        <dl className="card-facts">
          <dt>Job search</dt>
          <dd>{client.assigned_staff_id ? (nameOf.get(client.assigned_staff_id) ?? "—") : "nobody"}</dd>
          <dt>Billing</dt>
          <dd>{client.billing_staff_id ? (nameOf.get(client.billing_staff_id) ?? "—") : "nobody"}</dd>
          <dt>Counselor</dt>
          <dd>{counselor ? [counselor.name, counselor.office].filter(Boolean).join(" · ") : "—"}</dd>
          {client.phone && (
            <>
              <dt>Phone</dt>
              <dd>
                <a href={`tel:${client.phone.replace(/[^0-9+]/g, "")}`}>{client.phone}</a>
              </dd>
            </>
          )}
        </dl>

        {actions.length > 0 && (
          <>
            <h4 style={{ margin: "12px 0 4px" }}>What is next</h4>
            <ul className="lock" style={{ margin: 0, paddingLeft: 18 }}>
              {actions.map((a, i) => (
                <li key={i}>
                  <b>{a.title}</b> — {a.detail}
                </li>
              ))}
            </ul>
          </>
        )}

        <p style={{ margin: "12px 0 0" }}>
          <Link className="row-link" href={`/clients/${client.id}?tab=messages`}>
            Their messages
          </Link>{" "}
          ·{" "}
          <Link className="row-link" href={`/clients/${client.id}?tab=billing`}>
            Their billing
          </Link>
        </p>
      </div>
    </aside>
  );
}

/** The same shape where there is no client: a visitor, or a number nobody knows. */
export function StrangerCard({ who, conversationId }: { who: string; conversationId: string }) {
  return (
    <aside className="thread-aside">
      <div className="card">
        <h3 style={{ marginTop: 0 }}>{who}</h3>
        <p className="lock" style={{ marginTop: 0 }}>
          Not on any record. The work is to find out who this is.
        </p>
        <p style={{ margin: "10px 0 0", display: "flex", flexDirection: "column", gap: 6 }}>
          <Link className="row-link" href={`/messages/texts?tab=texts&c=${conversationId}&do=match`}>
            Match to a client
          </Link>
          <Link className="row-link" href={`/messages/texts?tab=texts&c=${conversationId}&do=referral`}>
            Create a referral
          </Link>
          <Link className="row-link" href={`/messages/texts?tab=texts&c=${conversationId}&do=spam`}>
            Mark as spam
          </Link>
        </p>
      </div>
    </aside>
  );
}
