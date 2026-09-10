import Link from "next/link";
import { redirect, notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ORG } from "@/lib/roles";
import { Section } from "./section";

/**
 * One client's record, gathered.
 *
 * Everything held about a person, in one document, meant to be read by a
 * person and then printed. Opening it produces it — gathering a record *is*
 * reading it, so there is no separate "produce" button that would let
 * somebody see the contents without the read being logged.
 *
 * Opening it again re-gathers as the record stands today rather than
 * replaying what was handed over before. That is the honest behaviour: a
 * stored copy would drift from the record it claims to be, and the question
 * "what did we send in March" is answered by the copy that was sent, not by
 * this screen.
 */
export default async function RecordsBundlePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const me = await requireStaff();
  if (me.role !== "Admin") redirect("/dashboard");

  const { id } = await params;
  const supabase = await createClient();

  const { data: request } = await supabase
    .from("records_requests")
    .select("id, client_id, client_name, requested_by, requested_on, note, produced_at")
    .eq("id", id)
    .maybeSingle();

  if (!request) notFound();

  const { data: bundle, error } = await supabase.rpc("records_request_bundle", {
    p_client: request.client_id,
    p_purpose: `Records request from ${request.requested_by}`,
  });

  if (error) {
    return (
      <>
        <h1 className="h1">Records request</h1>
        <div className="alert bad">{error.message}</div>
      </>
    );
  }

  const b = (bundle ?? {}) as Record<string, unknown>;
  const list = (key: string) => (Array.isArray(b[key]) ? (b[key] as Record<string, unknown>[]) : []);

  // Stamp the first production. Later openings do not overwrite who gathered
  // it first — that is the disclosure that happened.
  const contents = Object.fromEntries(
    Object.entries(b)
      .filter(([, v]) => Array.isArray(v))
      .map(([k, v]) => [k, (v as unknown[]).length]),
  );

  if (!request.produced_at) {
    await supabase
      .from("records_requests")
      .update({
        produced_at: new Date().toISOString(),
        produced_by: me.id,
        produced_by_name: me.name,
        contents,
      })
      .eq("id", id)
      .is("produced_at", null);
  }

  const empty = Object.entries(contents)
    .filter(([, n]) => n === 0)
    .map(([k]) => k.replace(/_/g, " "));

  return (
    <>
      <div className="no-print">
        <Link href="/admin/records-request">← All records requests</Link>
      </div>

      <h1 className="h1" style={{ marginTop: 8 }}>
        {request.client_name} — complete record
      </h1>
      <p className="sub">
        {ORG.name} · gathered {new Date().toLocaleDateString()} by {me.name} · requested by{" "}
        {request.requested_by} on {request.requested_on}
      </p>

      <div className="alert no-print" style={{ marginTop: 12 }}>
        <b>Read this before it leaves the building.</b> Notes carry the roles they were visible to
        — anything not visible to everybody was written for a narrower audience and may name
        somebody other than this client. Redact on the printed copy; nothing here edits the record.
      </div>

      <Section title="The client" data={b.client} />
      <Section title="Date of birth and address" data={b.restricted_details} />
      <Section title="Intake" data={b.intake} />
      <Section title="Stage history" rows={list("stage_history")} />
      <Section title="Case notes" rows={list("notes")} highlight="visible_roles" />
      <Section title="Counselor contacts" rows={list("counselor_contacts")} />
      <Section title="Authorizations" rows={list("authorizations")} />
      <Section title="Invoices" rows={list("invoices")} />
      <Section title="Service hours" rows={list("service_hours")} />
      <Section title="USOR forms" rows={list("forms")} />
      <Section title="Placements" rows={list("placements")} />
      <Section title="Jobs applied for" rows={list("jobs_applied_for")} />
      <Section title="Appointments" rows={list("appointments")} />
      <Section title="Tasks" rows={list("tasks")} />
      <Section title="Text messages" rows={list("texts")} />
      <Section title="Texting consent" rows={list("texting_consent")} />
      <Section title="Email" rows={list("email")} />
      <Section title="Files held" rows={list("files")} />
      <Section title="Who has opened this record" rows={list("who_read_this_record")} />

      {empty.length > 0 && (
        <div className="card" style={{ marginTop: 14 }}>
          <h3 style={{ marginTop: 0 }}>Held, and empty</h3>
          <p style={{ margin: 0 }}>
            Nothing is recorded under: {empty.join(", ")}.
          </p>
          <p className="lock" style={{ marginBottom: 0 }}>
            Listed rather than left out, so the person receiving this can see that the question was
            asked and the answer was none.
          </p>
        </div>
      )}

      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>The files themselves</h3>
        <p style={{ margin: 0 }}>
          {list("files").length === 0
            ? "No documents are held for this client."
            : `${list("files").length} document(s) are listed above by name. They are not part of this printout — attach them from the client's Files tab.`}
        </p>
      </div>

      <p className="lock no-print" style={{ marginTop: 14 }}>
        Gathering this was recorded in the access log against your name.
      </p>
    </>
  );
}
