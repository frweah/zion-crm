import Link from "next/link";
import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ROLE_LABEL, type Role } from "@/lib/roles";
import { DataTable } from "../../data-table";
import { InviteForm, StaffRowActions } from "./staff-forms";
import { StaffActivity } from "./staff-activity";
import { today } from "@/lib/constants";
import { Offboarding, type ReadinessRow, type OffboardedRow } from "./offboarding";

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

/**
 * Staff, a section of Admin → People.
 *
 * The accounts, inviting somebody, offboarding and the staff report. What is
 * held about one person - pay, checklists, certifications, documents - is on
 * that person's record (./../people/[id]), reached from their name, rather
 * than repeated here once per person.
 */
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

  const [{ data }, activityResult, readinessResult, offboardedResult] = await Promise.all([
    supabase
      .from("staff")
      .select("id, name, email, role, active, user_id, invited_at, accepted_at")
      .order("active", { ascending: false })
      .order("name"),
    supabase.rpc("staff_activity", { p_from: from, p_to: to }),
    supabase.from("offboarding_readiness").select("*").order("name"),
    supabase.from("staff_offboarding").select("*"),
  ]);

  const staff = (data ?? []) as StaffRow[];

  const statusOf = (s: StaffRow) =>
    !s.active ? "Inactive" : s.accepted_at ? "Active" : s.invited_at ? "Invited" : "Not invited";

  return (
    <>
      <h2 className="h2">Staff</h2>
      <p className="sub">
        Accounts, roles and access. Deactivating an account removes access the same moment —
        reassign that person&apos;s active clients first.
      </p>

      <div className="grid" style={{ gridTemplateColumns: "minmax(0, 2fr) minmax(280px, 1fr)" }}>
        <div>
          <h3 style={{ marginTop: 0 }}>Accounts</h3>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="staff accounts"
              columns={[
                { key: "name", label: "Name" },
                { key: "role", label: "Role" },
                { key: "status", label: "Status" },
                { key: "actions", label: "", sortable: false },
              ]}
              rows={staff.map((s) => {
                const status = statusOf(s);
                return {
                  key: s.id,
                  text: `${s.name} ${s.email} ${ROLE_LABEL[s.role]} ${status}`,
                  sort: { name: s.name, role: ROLE_LABEL[s.role], status },
                  cells: {
                    name: (
                      <>
                        <Link href={`/admin/people/${s.id}`}>
                          <b>{s.name}</b>
                        </Link>
                        <div className="lock">{s.email}</div>
                      </>
                    ),
                    role: ROLE_LABEL[s.role],
                    status: (
                      <span
                        className={
                          "chip " + (status === "Active" ? "ok" : status === "Inactive" ? "" : "warn")
                        }
                      >
                        {status}
                      </span>
                    ),
                    actions: (
                      <StaffRowActions
                        staffId={s.id}
                        email={s.email}
                        active={s.active}
                        accepted={Boolean(s.accepted_at)}
                        invited={Boolean(s.invited_at)}
                      />
                    ),
                  },
                };
              })}
              empty="There are no staff accounts yet."
            />
          </div>
          <p className="lock" style={{ marginTop: 8 }}>
            Pay rates, onboarding and offboarding checklists, certifications and documents are on
            each person&apos;s record — open it from their name.
          </p>
        </div>

        <div className="card">
          <h3>Invite a staff member</h3>
          <InviteForm />
        </div>
      </div>

      <Offboarding
        people={(readinessResult.data ?? []) as unknown as ReadinessRow[]}
        colleagues={staff.filter((s) => s.active).map((s) => ({ id: s.id, name: s.name }))}
        today={today()}
        offboarded={(offboardedResult.data ?? []) as unknown as OffboardedRow[]}
        nameOf={Object.fromEntries(staff.map((s) => [s.id, s.name]))}
      />

      <StaffActivity rows={(activityResult.data ?? []) as never} from={from} to={to} />
    </>
  );
}
