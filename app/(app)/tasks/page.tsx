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
    .select(
      "id, title, due, status, client_id, assigned_staff_id, system_generated, source_match_id, source_kind, parent_id, repeat_every, removed_by, removed_reason",
    );
  if (!isAdmin) query = query.eq("assigned_staff_id", me.id);

  const [tasksResult, clientsResult, staffResult] = await Promise.all([
    query,
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
    // Everybody, not only the people still here. Two different questions get
    // answered from this: who a task can be given to, which is the active
    // colleagues, and who took one off the list, which may be somebody who
    // has since left.
    supabase.from("staff").select("id, name, active, is_system").order("name"),
  ]);

  const clients = clientsResult.data ?? [];
  const everybody = staffResult.data ?? [];
  // Work is handed to colleagues who are here; names are read from everybody.
  const staff = everybody
    .filter((s) => s.active && !s.is_system)
    .map((s) => ({ id: s.id, name: s.name }));
  const clientName = new Map(clients.map((c) => [c.id, c.name]));
  const staffName = new Map(everybody.map((s) => [s.id, s.name]));

  const tasks: TaskListRow[] = (tasksResult.data ?? []).map((t) => ({
    id: t.id,
    title: t.title,
    due: t.due,
    status: t.status,
    client_id: t.client_id,
    system_generated: t.system_generated,
    source_match_id: t.source_match_id,
    source_kind: t.source_kind,
    client_name: t.client_id ? (clientName.get(t.client_id) ?? "—") : "",
    assigned_name: t.assigned_staff_id ? (staffName.get(t.assigned_staff_id) ?? "") : "",
    assigned_staff_id: t.assigned_staff_id,
    parent_id: t.parent_id,
    repeat_every: t.repeat_every,
    removed_by_name: t.removed_by ? (staffName.get(t.removed_by) ?? null) : null,
    removed_reason: t.removed_reason,
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
