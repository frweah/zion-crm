import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, CAN_LOG_HOURS } from "@/lib/constants";
import { can, ORG } from "@/lib/roles";
import { templatesForService } from "@/lib/form-templates";
import { CRP_STAGES } from "@/lib/crp-pathway";
import { PageHead } from "../../page-head";
import { BillFlow, type BillOption } from "../../bill-flow";
import { ClientPicker } from "./client-picker";

/**
 * Report &amp; bill, on one screen.
 *
 * The owner's layout (20 Sept 2026): pick the client, pick the authorization,
 * the form comes up pre-filled, it goes to the counselor. The same thing is
 * on every client's record, for when you are already holding the client; this
 * is for when you are not - a morning of billing is a list of people, not a
 * list of records to go and open one at a time.
 *
 * The flow itself is the same component either way, so the two cannot drift.
 */
export default async function ReportAndBillPage({
  searchParams,
}: {
  searchParams: Promise<{ client?: string }>;
}) {
  const me = await requireStaff();
  const { client: clientId } = await searchParams;
  const supabase = await createClient();

  if (!clientId) {
    return (
      <>
        <PageHead
          title="Report &amp; bill"
          context="Pick a client, pick the authorization, and the form comes up filled in"
        />
        <div className="card">
          <ClientPicker />
          <p className="lock" style={{ margin: "12px 0 0" }}>
            Or open a client&apos;s record and press <b>Report &amp; bill</b> there — it is the same three steps.
          </p>
        </div>
        <Pathway />
      </>
    );
  }

  const [{ data: client }, { data: openAuths }, { data: paperworkRows }, { data: office }, { data: authFiles }] =
    await Promise.all([
      supabase.from("clients").select("id, name, client_no, counselor_id").eq("id", clientId).maybeSingle(),
      supabase
        .from("authorizations")
        .select("id, number, service_type, rate, rate_type, total_hours, status")
        .eq("client_id", clientId)
        .eq("status", "Open")
        .order("end_date", { ascending: true, nullsFirst: false }),
      supabase.from("client_paperwork").select("auth_id, template_id, state").eq("client_id", clientId),
      supabase.from("client_billing_office").select("billing_office").eq("client_id", clientId).maybeSingle(),
      supabase.from("attachments").select("auth_id").eq("client_id", clientId).not("auth_id", "is", null),
    ]);

  if (!client) {
    return (
      <>
        <PageHead title="Report &amp; bill" context="That client is not on file" />
        <div className="card">
          <ClientPicker />
        </div>
      </>
    );
  }

  const { data: counselor } = client.counselor_id
    ? await supabase.from("counselors").select("name").eq("id", client.counselor_id).maybeSingle()
    : { data: null };
  const counselorName = counselor?.name ?? "";
  const withPdf = new Set((authFiles ?? []).map((f) => f.auth_id).filter(Boolean) as string[]);
  const paperwork = paperworkRows ?? [];

  const priceOf = (a: { rate: number | null; rate_type: string; total_hours: number | null }) =>
    a.rate_type === "Hourly" && a.total_hours != null
      ? `${Number(a.total_hours)} hrs @ ${money(Number(a.rate ?? 0))}`
      : `${money(Number(a.rate ?? 0))} flat`;

  const bills: BillOption[] = (openAuths ?? [])
    .map((a) => ({
      authId: a.id,
      label: `${a.service_type} · ${a.number || "no V-number"}`,
      service: a.service_type,
      number: a.number ?? "",
      price: priceOf(a),
      status: a.status,
      hasPdf: withPdf.has(a.id),
      templates: templatesForService(a.service_type)
        .filter((t) => t.requiredForBilling)
        .map((t) => ({
          id: t.id,
          usor: t.usor,
          name: t.name,
          monthly: Boolean(t.monthly),
          outstanding: paperwork.some((p) => p.auth_id === a.id && p.template_id === t.id && p.state !== "Complete"),
        })),
    }))
    .filter((b) => b.templates.length > 0);

  return (
    <>
      <PageHead
        title="Report &amp; bill"
        context={`${client.name}${client.client_no ? ` · Client #${client.client_no}` : ""}`}
        actions={
          <Link className="btn ghost" href={`/clients/${client.id}`} style={{ textDecoration: "none" }}>
            Open the record
          </Link>
        }
      />

      <div className="card" style={{ marginBottom: 14 }}>
        <ClientPicker current={client.name} />
      </div>

      <div className="card">
        <BillFlow
          clientId={client.id}
          bills={bills}
          counselorName={counselorName}
          agency={ORG.name}
          preparedBy={me.name}
          billingOffice={office?.billing_office ?? null}
        />
      </div>

      {!(CAN_LOG_HOURS.includes(me.role) || can(me, "billing", "edit")) && (
        <p className="lock" style={{ marginTop: 12 }}>
          Your role does not log service hours, so the hours on the form are whatever has already been logged.
        </p>
      )}
    </>
  );
}

/** What USOR publishes, for somebody who wants the whole shape of it. */
function Pathway() {
  return (
    <section className="card" style={{ marginTop: 14 }}>
      <h3 style={{ marginTop: 0 }}>The pathway, as USOR sets it out</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        Which form each service bills on, what date belongs on the invoice, and when it may be billed. The
        authorization&apos;s own rate is always what is billed — the published fee is here to compare against.
      </p>
      <div className="list">
        {CRP_STAGES.map((s) => (
          <div key={s.key} className="list-item">
            <h4 style={{ margin: "0 0 4px", fontSize: "var(--text-base)" }}>{s.label}</h4>
            <dl className="bill-facts" style={{ margin: 0 }}>
              <dt>Services</dt>
              <dd>{s.services.join(", ")}</dd>
              <dt>Invoice date</dt>
              <dd>{s.invoiceDate}</dd>
              <dt>Bill it when</dt>
              <dd>{s.billsWhen}</dd>
              {s.dueBy && (
                <>
                  <dt>Paperwork due</dt>
                  <dd>{s.dueBy}</dd>
                </>
              )}
              {s.fees.length > 0 && (
                <>
                  <dt>Published fee</dt>
                  <dd>{s.fees.map((f) => `${f.label} $${f.amount.toLocaleString("en-US")}`).join(" · ")}</dd>
                </>
              )}
            </dl>
          </div>
        ))}
      </div>
    </section>
  );
}
