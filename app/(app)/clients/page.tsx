import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ClientsView, type ClientRow } from "./clients-view";

const CAN_EDIT = ["Admin", "Job Search", "Reports"];

export default async function ClientsPage() {
  const staffMember = await requireStaff();
  const supabase = await createClient();

  // Fetched separately and joined here rather than as embedded selects: the
  // lists are small, and it keeps the queries readable and fully typed.
  const [clientsResult, counselorsResult, staffResult, officesResult] = await Promise.all([
    supabase
      .from("clients")
      .select(
        "id, name, client_no, stage, status, agency_id, referring_office, import_review, counselor_id, assigned_staff_id",
      )
      .order("name"),
    supabase.from("counselors").select("id, name").order("name"),
    supabase.from("staff").select("id, name").eq("active", true).order("name"),
    supabase.from("offices").select("name").order("name"),
  ]);

  const counselors = counselorsResult.data ?? [];
  const staff = staffResult.data ?? [];
  const counselorName = new Map(counselors.map((k) => [k.id, k.name]));
  const staffName = new Map(staff.map((s) => [s.id, s.name]));

  const clients: ClientRow[] = (clientsResult.data ?? []).map((c) => ({
    id: c.id,
    name: c.name,
    client_no: c.client_no,
    stage: c.stage,
    status: c.status,
    agency_id: c.agency_id,
    referring_office: c.referring_office,
    import_review: c.import_review,
    counselor_name: c.counselor_id ? (counselorName.get(c.counselor_id) ?? "") : "",
    assigned_name: c.assigned_staff_id ? (staffName.get(c.assigned_staff_id) ?? "") : "",
  }));

  return (
    <ClientsView
      clients={clients}
      counselors={counselors}
      staff={staff}
      offices={(officesResult.data ?? []).map((o) => o.name)}
      canEdit={CAN_EDIT.includes(staffMember.role)}
      roleNote={
        staffMember.role === "Reports"
          ? "All clients — complete intake from the client record"
          : "All clients"
      }
    />
  );
}
