import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ROLE_LABEL, type Role } from "@/lib/roles";
import { InviteForm, StaffRowActions } from "./staff-forms";

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

export default async function StaffPage() {
  await requireAdmin();
  const supabase = await createClient();

  const { data } = await supabase
    .from("staff")
    .select("id, name, email, role, active, user_id, invited_at, accepted_at")
    .order("active", { ascending: false })
    .order("name");

  const staff = (data ?? []) as StaffRow[];

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
    </>
  );
}
