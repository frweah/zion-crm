import Link from "next/link";
import { teamsChatHref } from "@/lib/teams";
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
 * Staff: HR → People.
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
      .select("id, name, email, role, active, user_id, invited_at, accepted_at, is_system")
      .order("active", { ascending: false })
      .order("name"),
    supabase.rpc("staff_activity", { p_from: from, p_to: to }),
    supabase.from("offboarding_readiness").select("*").order("name"),
    supabase.from("staff_offboarding").select("*"),
  ]);

  // The people, and apart from them the accounts that are not people (0120) -
  // the deploy check - so nobody reads it as a colleague.
  const all = (data ?? []) as (StaffRow & { is_system: boolean })[];
  const staff = all.filter((s) => !s.is_system) as StaffRow[];
  const systemAccounts = all.filter((s) => s.is_system);

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
                        {/*
                          The bridge to Teams (Messaging brief, B): the CRM's own
                          chat is for what belongs on a client's record, and Teams
                          is for the rest of the day. Wherever a colleague is
                          offered as somebody to contact, both are.
                        */}
                        {teamsChatHref([s.email]) && (
                          <a
                            className="lock"
                            href={teamsChatHref([s.email])!}
                            target="_blank"
                            rel="noopener noreferrer"
                          >
                            Message on Teams
                          </a>
                        )}
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

          {systemAccounts.length > 0 && (
            <section style={{ marginTop: 18 }} aria-labelledby="system-accounts">
              <h3 id="system-accounts" style={{ marginTop: 0 }}>
                System accounts
              </h3>
              <p className="lock" style={{ marginTop: 0 }}>
                Not people. The automated check signs in after every deploy and opens every screen Job Search can reach,
                so a screen that fails is caught before anybody meets it. It reads and cannot change anything, is never
                given more than Job Search, and its reads are logged like anybody&apos;s. Its password is held only in
                GitHub&apos;s secrets.
              </p>
              <ul className="day-list">
                {systemAccounts.map((s) => (
                  <li key={s.id}>
                    <span className="chip">System account</span>
                    <span className="day-main">
                      <Link href={`/admin/people/${s.id}`}>
                        <b>{s.name}</b>
                      </Link>
                      <span className="lock"> {s.email} · {ROLE_LABEL[s.role]}, read-only</span>
                    </span>
                    <span className={"chip " + (s.active ? "ok" : "")}>{s.active ? "Active" : "Inactive"}</span>
                  </li>
                ))}
              </ul>
            </section>
          )}
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
