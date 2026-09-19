import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp, today } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";
import { W4Form } from "../w4-form";
import { W9Form } from "../w9-form";
import { W8BenForm } from "../w8ben-form";
import { OpenButton } from "../../admin/staff/documents";
import { finishIfDone } from "./finish";
import {
  PersonalForm,
  IdentityUpload,
  CredentialForm,
  ConfirmCertifications,
  TaxFormChooser,
  PolicySignForm,
  PaymentForm,
  type Personal,
} from "./steps";

/**
 * The onboarding walkthrough (0100).
 *
 * Six steps, in order. Each is an item on the onboarding checklist and is done
 * when the thing itself is - read here from the same view Admin's checklist
 * reads, so the two cannot disagree. It opens on the first step not yet done;
 * a finished step can be opened again from the list to look or correct.
 */
const STEPS = [
  { key: "personal_details", label: "Personal details" },
  { key: "identity_documents", label: "Identity documents" },
  { key: "certifications_submitted", label: "Certifications" },
  { key: "tax_form_signed", label: "Tax form" },
  { key: "policy_signed", label: "Data-handling policy" },
  { key: "payment_setup", label: "Where you are paid" },
] as const;

type StepKey = (typeof STEPS)[number]["key"];

const BLANK: Personal = {
  legal_name: "",
  address_line1: "",
  address_line2: "",
  city: "",
  state: "",
  postal_code: "",
  phone: "",
  date_of_birth: null,
  emergency_name: "",
  emergency_relationship: "",
  emergency_phone: "",
};

export default async function OnboardingPage({ searchParams }: { searchParams: Promise<{ step?: string }> }) {
  const me = await requireStaff();
  const { step: rawStep } = await searchParams;
  const supabase = await createClient();

  const [
    { data: onboarding },
    { data: checklist },
    { data: personal },
    { data: employment },
    { data: profile },
    { data: docs },
    { data: creds },
    { data: types },
    { data: policy },
    { data: signatures },
    { data: payment },
    { data: org },
    { data: everyone },
  ] = await Promise.all([
    supabase.from("staff_onboarding").select("started_at, completed_at, certifications_confirmed_at").eq("staff_id", me.id).maybeSingle(),
    supabase
      .from("staff_checklist")
      .select("auto_key, auto_done")
      .eq("staff_id", me.id)
      .in("auto_key", STEPS.map((s) => s.key)),
    supabase.from("staff_personal").select("*").eq("staff_id", me.id).maybeSingle(),
    supabase.from("staff_employment").select("employment_type").eq("staff_id", me.id).maybeSingle(),
    supabase.from("contractor_profiles").select("tax_status").eq("staff_id", me.id).maybeSingle(),
    supabase
      .from("staff_documents")
      .select("id, filename, category, note, created_at, inspection_required, inspected_at, inspected_by_name")
      .eq("staff_id", me.id)
      .in("category", ["I-9", "Identity document"])
      .order("created_at"),
    supabase
      .from("staff_credential_status")
      .select("type_key, label, required, state, expires_on, sort_order")
      .eq("staff_id", me.id)
      .eq("kind", "certificate")
      .order("sort_order"),
    supabase.from("credential_types").select("key, expires, detail").eq("active", true).eq("kind", "certificate"),
    supabase.from("staff_policies").select("key, version, title, body").eq("key", "data-handling").eq("is_current", true).maybeSingle(),
    supabase.from("staff_policy_signatures").select("policy_version, signer_name, signed_at").eq("staff_id", me.id),
    supabase
      .from("staff_payment_setup")
      .select("method, method_other, last_four, payer_of_record, confirmed_at")
      .eq("staff_id", me.id)
      .maybeSingle(),
    supabase.from("org_settings").select("employer_legal_name, payroll_service").maybeSingle(),
    me.role === "Admin"
      ? supabase.from("staff_onboarding").select("staff_id, started_at, completed_at, staff:staff!staff_onboarding_staff_id_fkey(name, active)")
      : Promise.resolve({ data: null }),
  ]);

  const done = new Map((checklist ?? []).map((c) => [c.auto_key as string, c.auto_done === true]));
  const open = STEPS.filter((s) => !done.get(s.key));
  const allDone = open.length === 0;

  // Finished just now - on this load, or with the tax form on Paperwork.
  if (onboarding && !onboarding.completed_at && allDone) await finishIfDone(me.id, me.name);

  const current: StepKey | null =
    (STEPS.find((s) => s.key === rawStep)?.key as StepKey | undefined) ?? (open[0]?.key as StepKey | undefined) ?? null;

  const employee = employment?.employment_type === "Employee";
  const legalName = personal?.legal_name || me.name;
  const signed = (signatures ?? []).find((s) => s.policy_version === policy?.version);
  const expiresOf = new Map((types ?? []).map((t) => [t.key, t.expires]));
  const detailOf = new Map((types ?? []).map((t) => [t.key, t.detail]));
  const taxForm = employee ? "W-4" : profile?.tax_status === "Foreign person" ? "W-8BEN" : profile?.tax_status === "US person" ? "W-9" : null;

  const intro = !onboarding
    ? "You joined before the walkthrough existed, so nothing here is required of you - but every step can still be done here."
    : allDone
      ? "All six steps are done. The administrator has been told."
      : `${STEPS.length - open.length} of ${STEPS.length} done. You can stop at any point and pick up where you left off.`;

  return (
    <>
      <PageHead title="Onboarding" context={intro} />

      <ol className="card" style={{ listStyle: "none", padding: 12, margin: "0 0 14px", display: "flex", flexWrap: "wrap", gap: 8 }}>
        {STEPS.map((s, i) => {
          const isDone = done.get(s.key) === true;
          const here = s.key === current;
          return (
            <li key={s.key}>
              <Link
                href={`/paperwork/onboarding?step=${s.key}`}
                className={"chip" + (isDone ? " ok" : "")}
                aria-current={here ? "step" : undefined}
                style={{ textDecoration: "none", outline: here ? "2px solid var(--teal)" : undefined, outlineOffset: 2 }}
              >
                {i + 1}. {s.label} {isDone ? "✓" : ""}
              </Link>
            </li>
          );
        })}
      </ol>

      {allDone && !rawStep && (
        <div className="card" style={{ marginBottom: 14 }}>
          <h3>You are onboarded</h3>
          <p className="sub" style={{ margin: 0 }}>
            Thank you. The administrator will check your certifications against the scans
            {employee ? " and inspect your I-9 documents in person - bring the originals on your first day" : ""}. Your
            documents and forms stay on <Link href="/paperwork">Paperwork</Link>.
          </p>
          <p style={{ margin: "12px 0 0" }}>
            <Link className="btn gold" href="/dashboard" style={{ textDecoration: "none" }}>
              Go to the dashboard
            </Link>
          </p>
        </div>
      )}

      {current === "personal_details" && (
        <section className="card" style={{ marginBottom: 14 }}>
          <h3>1. Personal details</h3>
          <PersonalForm personal={{ ...BLANK, ...(personal ?? {}), legal_name: legalName }} today={today()} />
        </section>
      )}

      {current === "identity_documents" && (
        <section className="card" style={{ marginBottom: 14 }}>
          <h3>2. Identity documents</h3>
          {!employment ? (
            <p className="sub" style={{ marginTop: 0 }}>
              Waiting on the administrator, who has not yet recorded whether you are an employee or a contractor. The
              other steps can be done meanwhile.
            </p>
          ) : employee ? (
            <div className="alert" style={{ marginTop: 0 }}>
              Upload a scan or photo of each document you will bring for your Form I-9 - nothing else is asked for here.
              The administrator completes your I-9 in person, from the originals, and marks each document inspected then;
              until that, each one reads <b>in-person inspection still required</b>.
            </div>
          ) : (
            <p className="sub" style={{ marginTop: 0 }}>A scan or photo of a photo ID.</p>
          )}
          {(docs ?? []).length > 0 && (
            <div className="card" style={{ padding: 0 }}>
              <DataTable
                label="documents"
                columns={[
                  { key: "doc", label: "Document" },
                  { key: "state", label: "Inspection" },
                  { key: "open", label: "", sortable: false },
                ]}
                rows={(docs ?? []).map((d) => ({
                  key: d.id!,
                  cells: {
                    doc: (
                      <>
                        <b>{d.note || d.filename}</b>
                        <div className="lock">
                          {d.filename} · {fmtStamp(d.created_at)}
                        </div>
                      </>
                    ),
                    state:
                      d.category !== "I-9" ? (
                        <span className="lock">Not needed</span>
                      ) : d.inspection_required ? (
                        <span className="chip warn">In-person inspection still required</span>
                      ) : (
                        <span className="chip ok">
                          Inspected {d.inspected_at ? fmtStamp(d.inspected_at) : ""}
                          {d.inspected_by_name ? ` by ${d.inspected_by_name}` : ""}
                        </span>
                      ),
                    open: <OpenButton id={d.id!} />,
                  },
                  sort: { doc: d.note || d.filename, state: d.inspection_required ? 0 : 1 },
                }))}
                empty="Nothing uploaded yet."
              />
            </div>
          )}
          {employment && <IdentityUpload employee={employee} />}
        </section>
      )}

      {current === "certifications_submitted" && (
        <section className="card" style={{ marginBottom: 14 }}>
          <h3>3. Certifications</h3>
          <p className="sub" style={{ marginTop: 0 }}>
            Put forward each card you hold, with its expiry date and a scan. The administrator checks each one against
            the scan. Anything you do not hold yet is fine - say so below, and it stays on your list until you do.
          </p>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="certifications"
              columns={[
                { key: "what", label: "Certification" },
                { key: "state", label: "Where it stands" },
                { key: "add", label: "", sortable: false },
              ]}
              rows={(creds ?? []).map((c) => ({
                key: c.type_key!,
                cells: {
                  what: (
                    <>
                      <b>{c.label}</b>
                      <div className="lock">{detailOf.get(c.type_key!) ?? ""}</div>
                    </>
                  ),
                  state: (
                    <span
                      className={
                        "chip " +
                        (c.state === "Valid" ? "ok" : c.state === "Missing" || c.state === "Expired" ? "bad" : "warn")
                      }
                    >
                      {c.state === "Missing" ? "Not put forward" : c.state}
                      {c.expires_on ? ` · expires ${c.expires_on}` : ""}
                    </span>
                  ),
                  add: (
                    <CredentialForm typeKey={c.type_key!} label={c.label ?? ""} expires={expiresOf.get(c.type_key!) ?? true} />
                  ),
                },
                sort: { what: c.label, state: c.state },
              }))}
              empty="Nothing is required of your role."
            />
          </div>
          {onboarding?.certifications_confirmed_at ? (
            <p className="lock" style={{ marginTop: 10 }}>
              You confirmed this list on {fmtStamp(onboarding.certifications_confirmed_at)}.
            </p>
          ) : (
            <ConfirmCertifications />
          )}
        </section>
      )}

      {current === "tax_form_signed" && (
        <section className="card" style={{ marginBottom: 14 }}>
          <h3>4. Tax form</h3>
          {done.get("tax_form_signed") ? (
            <p className="sub" style={{ margin: 0 }}>
              Your {taxForm ?? "tax form"} is signed and on file. If anything on it changes, complete a new one on{" "}
              <Link href="/paperwork">Paperwork</Link>.
            </p>
          ) : !employment ? (
            <p className="sub" style={{ margin: 0 }}>
              Waiting on the administrator, who has not yet recorded whether you are an employee or a contractor - that
              decides which form is yours.
            </p>
          ) : taxForm === "W-4" ? (
            <W4Form defaultName={legalName} />
          ) : taxForm === "W-9" ? (
            <W9Form defaultName={legalName} />
          ) : taxForm === "W-8BEN" ? (
            <W8BenForm defaultName={legalName} />
          ) : (
            <TaxFormChooser defaultName={legalName} />
          )}
        </section>
      )}

      {current === "policy_signed" && (
        <section className="card" style={{ marginBottom: 14 }}>
          <h3>5. {policy?.title ?? "Data-handling policy"}</h3>
          {!policy ? (
            <p className="sub">The policy is not on file. Tell the administrator.</p>
          ) : (
            <>
              <div style={{ maxWidth: "70ch" }}>
                {(policy.body as unknown as { type: string; text: string }[]).map((b, i) =>
                  b.type === "h2" ? (
                    <h4 key={i} style={{ margin: "16px 0 6px" }}>
                      {b.text}
                    </h4>
                  ) : b.type === "li" ? (
                    <p key={i} style={{ margin: "0 0 8px", paddingLeft: 14, borderLeft: "2px solid var(--line)" }}>
                      {b.text}
                    </p>
                  ) : (
                    <p key={i} style={{ margin: "0 0 10px" }}>
                      {b.text}
                    </p>
                  ),
                )}
              </div>
              {signed ? (
                <div className="alert ok" style={{ marginTop: 12 }}>
                  Signed by {signed.signer_name} on {fmtStamp(signed.signed_at)}. The signed copy is on your file.
                </div>
              ) : (
                <PolicySignForm version={policy.version} legalName={legalName} />
              )}
            </>
          )}
        </section>
      )}

      {current === "payment_setup" && (
        <section className="card" style={{ marginBottom: 14 }}>
          <h3>6. Where you are paid</h3>
          {payment && (
            <div className="alert ok">
              Saved {fmtStamp(payment.confirmed_at)}: {payment.method === "Other" ? payment.method_other : payment.method}
              {payment.last_four ? `, account ending ${payment.last_four}` : ""}. Paid by {payment.payer_of_record}.
            </div>
          )}
          <PaymentForm
            payer={org?.employer_legal_name ?? ""}
            payroll={org?.payroll_service ?? ""}
            current={payment ? { method: payment.method, method_other: payment.method_other, last_four: payment.last_four } : null}
          />
        </section>
      )}

      {current && (
        <p className="lock">
          {done.get(current) && open.length > 0 && (
            <>
              This step is done.{" "}
              <Link href={`/paperwork/onboarding?step=${open[0].key}`}>Next: {open[0].label}</Link>
            </>
          )}
        </p>
      )}

      {me.role === "Admin" && everyone && everyone.length > 0 && (
        <section style={{ marginTop: 24 }}>
          <h2 className="h2">Everyone being onboarded</h2>
          <div className="card" style={{ padding: 0, marginTop: 8 }}>
            <DataTable
              label="people"
              columns={[
                { key: "who", label: "Who" },
                { key: "started", label: "Started" },
                { key: "state", label: "Where they are" },
              ]}
              rows={everyone.map((o) => {
                const person = Array.isArray(o.staff) ? o.staff[0] : o.staff;
                return {
                  key: o.staff_id,
                  cells: {
                    who: (
                      <Link href={`/admin/people/${o.staff_id}`} style={{ color: "var(--teal)" }}>
                        <b>{person?.name ?? "—"}</b>
                      </Link>
                    ),
                    started: fmtStamp(o.started_at),
                    state: o.completed_at ? (
                      <span className="chip ok">Finished {fmtStamp(o.completed_at)}</span>
                    ) : (
                      <span className="chip warn">In progress - see their checklist</span>
                    ),
                  },
                  sort: { who: person?.name ?? "", started: o.started_at, state: o.completed_at ?? "" },
                };
              })}
              empty="Nobody is being onboarded."
            />
          </div>
        </section>
      )}
    </>
  );
}
