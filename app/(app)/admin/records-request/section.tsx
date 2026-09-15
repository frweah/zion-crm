import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { DataTable } from "../../data-table";
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
      <h2 className="h2">Records requests</h2>
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

      <h3 style={{ marginTop: 22 }}>Waiting</h3>
      <div className="card" style={{ marginTop: 12, padding: 0 }}>
        <DataTable
          label="waiting requests"
          columns={[
            { key: "asked", label: "Asked" },
            { key: "whose", label: "Whose record" },
            { key: "who", label: "Who asked" },
            { key: "note", label: "Note" },
            { key: "open", label: "", sortable: false },
          ]}
          rows={open.map((r) => ({
            key: r.id,
            cells: {
              asked: r.requested_on,
              whose: r.client_name,
              who: r.requested_by,
              note: r.note,
              open: (
                <Link className="btn gold" href={`/admin/documents/records-request/${r.id}`}>
                  Gather it
                </Link>
              ),
            },
          }))}
          empty="Nothing is waiting."
        />
      </div>

      <h3 style={{ marginTop: 22 }}>Already gathered</h3>
      <div className="card" style={{ marginTop: 12, padding: 0 }}>
        <DataTable
          label="gathered requests"
          columns={[
            { key: "asked", label: "Asked" },
            { key: "whose", label: "Whose record" },
            { key: "who", label: "Who asked" },
            { key: "gathered", label: "Gathered" },
            { key: "by", label: "By" },
            { key: "open", label: "", sortable: false },
          ]}
          rows={answered.map((r) => ({
            key: r.id,
            sort: { gathered: r.produced_at },
            cells: {
              asked: r.requested_on,
              whose: r.client_name,
              who: r.requested_by,
              gathered: new Date(r.produced_at!).toLocaleDateString(),
              by: r.produced_by_name,
              open: (
                <Link className="btn" href={`/admin/documents/records-request/${r.id}`}>
                  Open again
                </Link>
              ),
            },
          }))}
          empty="Nothing has been gathered yet."
        />
        {answered.length > 0 && (
          <p className="lock" style={{ margin: 0, padding: "10px 14px 14px" }}>
            Opening one again gathers the record as it stands today, not as it stood then, and is
            logged as a fresh read.
          </p>
        )}
      </div>
    </>
  );
}
