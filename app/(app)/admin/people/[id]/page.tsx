import { notFound } from "next/navigation";
import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ROLE_LABEL, type Role } from "@/lib/roles";
import { today } from "@/lib/constants";
import { RecordHeader } from "../../../record-header";
import { StaffRowActions } from "../../staff/staff-forms";
import { Checklist, type ChecklistRow } from "../../staff/checklist-forms";
import { PayRates, type PayRow } from "../../staff/pay-forms";
import {
  StaffCredentials,
  CeForm,
  type CredentialType,
  type StatusRow,
} from "../../staff/credentials";
import { StaffDocuments, type DocCategory, type DocRow } from "../../staff/documents";

/**
 * One member of staff's record.
 *
 * Pay, checklists, certifications and documents used to be repeated once per
 * person down Admin → People - a stack of cards with a name on each, where
 * finding one person's CPR card meant scrolling past everybody else's. They
 * are the same components here, read for one person, under the same record
 * header a client has.
 */
export default async function StaffRecordPage({ params }: { params: Promise<{ id: string }> }) {
  await requireAdmin();
  const { id } = await params;
  const supabase = await createClient();

  const { data: person } = await supabase
    .from("staff")
    .select("id, name, email, role, active, user_id, invited_at, accepted_at")
    .eq("id", id)
    .maybeSingle();

  if (!person) notFound();

  const [payResult, checklistResult, credentialResult, typesResult, employmentResult, documentResult, docCategoryResult] =
    await Promise.all([
      supabase
        .from("staff_pay")
        .select("id, staff_id, pay_rate, rate_unit, effective_from, note")
        .eq("staff_id", id)
        .order("effective_from", { ascending: false }),
      supabase.from("staff_checklist").select("*").eq("staff_id", id).order("sort_order"),
      supabase.from("staff_credential_status").select("*").eq("staff_id", id).order("sort_order"),
      supabase
        .from("credential_types")
        .select("key, label, detail, kind, expires, months_valid, applies_to, hours_target")
        .eq("active", true)
        .order("sort_order"),
      supabase.from("staff_employment").select("staff_id, transports_clients").eq("staff_id", id),
      supabase
        .from("staff_documents")
        .select("*")
        .eq("staff_id", id)
        .order("created_at", { ascending: false }),
      supabase
        .from("staff_file_categories")
        .select("key, label, detail, system_only")
        .eq("active", true)
        .order("sort_order"),
    ]);

  const checklist = (checklistResult.data ?? []) as ChecklistRow[];
  const transports = Boolean((employmentResult.data ?? [])[0]?.transports_clients);
  const onboarding = checklist.filter((r) => r.phase === "Onboarding");
  const offboarding = checklist.filter((r) => r.phase === "Offboarding");

  const account = person.accepted_at ? "Active" : person.invited_at ? "Invited" : "Not invited";

  return (
    <>
      <RecordHeader
        back={{ href: "/admin/people", label: "People" }}
        title={person.name}
        status={person.active ? null : "Inactive"}
        identity={[person.email, ROLE_LABEL[person.role as Role] ?? person.role]}
        standing={
          <>
            Account{" "}
            <span className={"chip " + (account === "Active" ? "ok" : "warn")}>{account}</span>
          </>
        }
        actions={
          <StaffRowActions
            staffId={person.id}
            email={person.email ?? ""}
            active={person.active}
            accepted={Boolean(person.accepted_at)}
            invited={Boolean(person.invited_at)}
          />
        }
      />

      <section id="pay" className="page-section">
        <h2 className="h2">Pay rates</h2>
        <p className="sub">
          A rate is a dated record rather than a field, so setting a new one adds to the history and
          work done before that date keeps the rate it was done under.
        </p>
        <PayRates
          staffId={person.id}
          name={person.name}
          rows={(payResult.data ?? []) as PayRow[]}
          today={today()}
        />
      </section>

      <section id="onboarding" className="page-section">
        <h2 className="h2">{person.active ? "Onboarding" : "Onboarding and offboarding"}</h2>
        <p className="sub">
          Items the system can answer for itself are answered for itself, and cannot be ticked. They
          become done when the thing is done. The rest are yours to mark.
        </p>
        {onboarding.length === 0 ? (
          <p className="empty">There is no onboarding checklist for {person.name}.</p>
        ) : (
          <Checklist name={person.name} rows={checklist} phase="Onboarding" />
        )}
        {!person.active &&
          (offboarding.length === 0 ? (
            <p className="empty">There is no offboarding checklist for {person.name}.</p>
          ) : (
            <Checklist name={person.name} rows={checklist} phase="Offboarding" />
          ))}
      </section>

      <section id="certifications" className="page-section">
        <h2 className="h2">Certifications and clearances</h2>
        <p className="sub">
          ACRE, CPR and First Aid, background clearance, continuing education — and a licence and
          insurance for anybody who transports clients. A renewal is recorded beside the old one,
          never over it.
        </p>
        <StaffCredentials
          staffId={person.id}
          staffName={person.name}
          rows={(credentialResult.data ?? []) as unknown as StatusRow[]}
          types={(typesResult.data ?? []) as CredentialType[]}
          transports={transports}
        />

        <h3>Log continuing education for {person.name.split(" ")[0]}</h3>
        <p className="sub" style={{ marginBottom: 8 }}>
          People log their own on their Paperwork screen. This is for the certificate that arrives by
          email addressed to the practice.
        </p>
        <CeForm staffId={person.id} today={today()} forSomebodyElse />
      </section>

      <section id="documents" className="page-section">
        <h2 className="h2">Documents</h2>
        <p className="sub">
          Everything held on their file. Opening one is recorded in the access log; a tax form signed
          in the app appears here too and cannot be removed from here.
        </p>
        <StaffDocuments
          staffId={person.id}
          staffName={person.name}
          docs={(documentResult.data ?? []) as unknown as DocRow[]}
          categories={(docCategoryResult.data ?? []) as DocCategory[]}
          canDelete
        />
      </section>
    </>
  );
}
