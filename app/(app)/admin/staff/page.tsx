import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ROLE_LABEL, type Role } from "@/lib/roles";
import { InviteForm, StaffRowActions } from "./staff-forms";
import { Checklist, type ChecklistRow } from "./checklist-forms";
import { StaffActivity } from "./staff-activity";
import { PayRates, type PayRow } from "./pay-forms";
import { today } from "@/lib/constants";
import {
  StaffCredentials,
  CeForm,
  type CredentialType,
  type StatusRow,
} from "./credentials";

type StaffRow = {
  id: string;
  name: string;
  email: string;
  role: Role;
  active: boolean;
  user_id: string | null;
  invited_at: string | null;
  accepted_at: string | null;
};

export default async function StaffPage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  await requireAdmin();
  const supabase = await createClient();

  const params = await searchParams;
  const to = params.to ?? today();
  const from = params.from ?? to.slice(0, 4) + "-01-01";

  const [
    { data },
    checklistResult,
    activityResult,
    payResult,
    credentialResult,
    typesResult,
    employmentResult,
  ] = await Promise.all([
    supabase
      .from("staff")
      .select("id, name, email, role, active, user_id, invited_at, accepted_at")
      .order("active", { ascending: false })
      .order("name"),
    supabase.from("staff_checklist").select("*").order("sort_order"),
    supabase.rpc("staff_activity", { p_from: from, p_to: to }),
    supabase
      .from("staff_pay")
      .select("id, staff_id, pay_rate, rate_unit, effective_from, note")
      .order("effective_from", { ascending: false }),
    supabase.from("staff_credential_status").select("*").order("sort_order"),
    supabase
      .from("credential_types")
      .select("key, label, detail, kind, expires, months_valid, applies_to, hours_target")
      .eq("active", true)
      .order("sort_order"),
    supabase.from("staff_employment").select("staff_id, transports_clients"),
  ]);

  const staff = (data ?? []) as StaffRow[];

  const payByStaff = new Map<string, PayRow[]>();
  for (const row of (payResult.data ?? []) as PayRow[]) {
    const list = payByStaff.get(row.staff_id) ?? [];
    list.push(row);
    payByStaff.set(row.staff_id, list);
  }

  const credentialTypes = (typesResult.data ?? []) as CredentialType[];
  const transports = new Map(
    (employmentResult.data ?? []).map((e) => [e.staff_id, Boolean(e.transports_clients)]),
  );

  const credentialsByStaff = new Map<string, StatusRow[]>();
  for (const row of (credentialResult.data ?? []) as unknown as StatusRow[]) {
    const list = credentialsByStaff.get(row.staff_id) ?? [];
    list.push(row);
    credentialsByStaff.set(row.staff_id, list);
  }

  const checklistByStaff = new Map<string, ChecklistRow[]>();
  for (const row of (checklistResult.data ?? []) as ChecklistRow[]) {
    const list = checklistByStaff.get(row.staff_id) ?? [];
    list.push(row);
    checklistByStaff.set(row.staff_id, list);
  }

  return (
    <>
      <h1 className="h1">Staff</h1>
      <p className="sub">
        Accounts, roles and access. Deactivating an account removes access the same moment —
        reassign that person&apos;s active clients first.
      </p>

      <div className="grid" style={{ gridTemplateColumns: "minmax(0, 2fr) minmax(280px, 1fr)" }}>
        <div className="card">
          <h3>Accounts</h3>
          <table className="t">
            <thead>
              <tr>
                <th>Name</th>
                <th>Role</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {staff.map((s) => (
                <tr key={s.id}>
                  <td>
                    <b>{s.name}</b>
                    <div style={{ fontSize: 12, color: "var(--muted)" }}>{s.email}</div>
                  </td>
                  <td>{ROLE_LABEL[s.role]}</td>
                  <td>
                    {!s.active ? (
                      <span className="chip">Inactive</span>
                    ) : s.accepted_at ? (
                      <span className="chip ok">Active</span>
                    ) : s.invited_at ? (
                      <span className="chip warn">Invited</span>
                    ) : (
                      <span className="chip warn">Not invited</span>
                    )}
                  </td>
                  <td style={{ textAlign: "right" }}>
                    <StaffRowActions
                      staffId={s.id}
                      email={s.email}
                      active={s.active}
                      accepted={Boolean(s.accepted_at)}
                      invited={Boolean(s.invited_at)}
                    />
                  </td>
                </tr>
              ))}
              {staff.length === 0 && (
                <tr>
                  <td colSpan={4} className="empty">
                    No staff accounts yet.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        <div className="card">
          <h3>Invite a staff member</h3>
          <InviteForm />
        </div>
      </div>

      <h3 style={{ marginTop: 24 }}>Pay rates</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        A rate is a dated record rather than a field, so setting a new one adds to the history and
        work done before that date keeps the rate it was done under. Each person can see their own
        rate and nobody else&apos;s.
      </p>
      {staff
        .filter((s) => s.active)
        .map((s) => (
          <PayRates
            key={s.id}
            staffId={s.id}
            name={s.name}
            rows={payByStaff.get(s.id) ?? []}
            today={today()}
          />
        ))}

      <h3 style={{ marginTop: 24 }}>Onboarding and offboarding</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        Items the system can answer for itself are answered for itself, and cannot be ticked. They
        become done when the thing is done. The rest are yours to mark.
      </p>
      {staff
        .filter((s) => checklistByStaff.has(s.id))
        .map((s) => (
          <div key={s.id}>
            <Checklist name={s.name} rows={checklistByStaff.get(s.id) ?? []} phase="Onboarding" />
            {!s.active && (
              <Checklist name={s.name} rows={checklistByStaff.get(s.id) ?? []} phase="Offboarding" />
            )}
          </div>
        ))}

      <h1 className="h1" style={{ fontSize: 18, marginTop: 26 }}>
        Certifications and clearances
      </h1>
      <p className="sub">
        ACRE, CPR and First Aid, background clearance, continuing education — and a licence and
        insurance for anybody who transports clients. A renewal is recorded beside the old one,
        never over it.
      </p>

      {staff
        .filter((s) => s.active)
        .map((s) => (
          <StaffCredentials
            key={s.id}
            staffId={s.id}
            staffName={s.name}
            rows={credentialsByStaff.get(s.id) ?? []}
            types={credentialTypes}
            transports={transports.get(s.id) ?? false}
          />
        ))}

      <div className="card" style={{ marginBottom: 14 }}>
        <h3 style={{ marginTop: 0 }}>Log continuing education for somebody</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          People log their own on their Paperwork screen. This is for the certificate that arrives
          by email addressed to the practice.
        </p>
        {staff
          .filter((s) => s.active)
          .map((s) => (
            <div key={s.id} style={{ marginBottom: 10 }}>
              <div className="lock" style={{ marginBottom: 4 }}>
                {s.name}
              </div>
              <CeForm staffId={s.id} today={today()} forSomebodyElse />
            </div>
          ))}
      </div>

      <StaffActivity
        rows={(activityResult.data ?? []) as never}
        from={from}
        to={to}
      />
    </>
  );
}
