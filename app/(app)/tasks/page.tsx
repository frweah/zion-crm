import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { TasksView, type TaskListRow } from "./tasks-view";

export default async function TasksPage() {
  const me = await requireStaff();
  const supabase = await createClient();
  const isAdmin = me.role === "Admin";

  // Admin runs the board; everyone else works their own list. The prototype
  // draws the same line.
  let query = supabase
    .from("tasks")
    .select("id, title, due, status, client_id, assigned_staff_id, system_generated");
  if (!isAdmin) query = query.eq("assigned_staff_id", me.id);

  const [tasksResult, clientsResult, staffResult] = await Promise.all([
    query,
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
    supabase.from("staff").select("id, name").eq("active", true).order("name"),
  ]);

  const clients = clientsResult.data ?? [];
  const staff = staffResult.data ?? [];
  const clientName = new Map(clients.map((c) => [c.id, c.name]));
  const staffName = new Map(staff.map((s) => [s.id, s.name]));

  const tasks: TaskListRow[] = (tasksResult.data ?? []).map((t) => ({
    id: t.id,
    title: t.title,
    due: t.due,
    status: t.status,
    client_id: t.client_id,
    system_generated: t.system_generated,
    client_name: t.client_id ? (clientName.get(t.client_id) ?? "—") : "",
    assigned_name: t.assigned_staff_id ? (staffName.get(t.assigned_staff_id) ?? "") : "",
  }));

  return (
    <TasksView
      tasks={tasks}
      clients={clients}
      staff={staff}
      isAdmin={isAdmin}
      myId={me.id}
      scopeNote={isAdmin ? "All staff" : "Assigned to you"}
    />
  );
}
