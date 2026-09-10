import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { RequestForm } from "./request-form";

/**
 * Records requests.
 *
 * Admin only, throughout. Answering one is a disclosure decision — what may
 * go out and what has to be reviewed first — and this is a practice where one
 * person makes those.
 */
export default async function RecordsRequestPage() {
  const me = await requireStaff();
  if (me.role !== "Admin") redirect("/dashboard");

  const supabase = await createClient();

  const [{ data: clients }, { data: requests }] = await Promise.all([
    supabase.from("clients").select("id, name").order("name"),
    supabase
      .from("records_requests")
      .select(
        "id, client_id, client_name, requested_by, requested_on, note, produced_at, produced_by_name",
      )
      .order("requested_on", { ascending: false })
      .limit(200),
  ]);

  const open = (requests ?? []).filter((r) => !r.produced_at);
  const answered = (requests ?? []).filter((r) => r.produced_at);

  return (
    <>
      <h1 className="h1">Records requests</h1>
      <p className="sub">
        {open.length} waiting · {answered.length} gathered
      </p>

      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>What this produces, and what it does not</h3>
        <p style={{ margin: 0 }}>
          Opening a request gathers everything held about that person into one document you can
          read and print: their record, notes, forms, invoices, texts, appointments, the list of
          files held, and who has opened their file.
        </p>
        <p className="lock" style={{ marginBottom: 0 }}>
          Nothing is sent from here. A case note can name another client, an employer&rsquo;s
          private remark or a family member, so what may be disclosed is a judgement — every entry
          says who could see it, and somebody reads it before it goes. Gathering a record is
          itself recorded in the access log.
        </p>
      </div>

      <RequestForm clients={clients ?? []} today={today()} />

      <h2 className="h1" style={{ fontSize: 20, marginTop: 22 }}>Waiting</h2>
      {open.length === 0 ? (
        <div className="empty">Nothing is waiting.</div>
      ) : (
        <div className="card" style={{ marginTop: 12 }}>
          <table className="t">
            <thead>
              <tr>
                <th>Asked</th>
                <th>Whose record</th>
                <th>Who asked</th>
                <th>Note</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {open.map((r) => (
                <tr key={r.id}>
                  <td>{r.requested_on}</td>
                  <td>{r.client_name}</td>
                  <td>{r.requested_by}</td>
                  <td>{r.note}</td>
                  <td>
                    <Link className="btn gold" href={`/admin/records-request/${r.id}`}>
                      Gather it
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <h2 className="h1" style={{ fontSize: 20, marginTop: 22 }}>Already gathered</h2>
      {answered.length === 0 ? (
        <div className="empty">Nothing has been gathered yet.</div>
      ) : (
        <div className="card" style={{ marginTop: 12 }}>
          <table className="t">
            <thead>
              <tr>
                <th>Asked</th>
                <th>Whose record</th>
                <th>Who asked</th>
                <th>Gathered</th>
                <th>By</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {answered.map((r) => (
                <tr key={r.id}>
                  <td>{r.requested_on}</td>
                  <td>{r.client_name}</td>
                  <td>{r.requested_by}</td>
                  <td>{new Date(r.produced_at!).toLocaleDateString()}</td>
                  <td>{r.produced_by_name}</td>
                  <td>
                    <Link className="btn" href={`/admin/records-request/${r.id}`}>
                      Open again
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="lock" style={{ marginBottom: 0 }}>
            Opening one again gathers the record as it stands today, not as it stood then, and is
            logged as a fresh read.
          </p>
        </div>
      )}
    </>
  );
}
