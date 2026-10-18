import { createClient } from "@/lib/supabase/server";
import { ProblemList, type ProblemRow } from "./problem-list";

/**
 * What staff have said is wrong with the CRM (0216).
 *
 * Open ones first and newest first, because an open report is a job and a
 * closed one is a record. Thirty days of closed ones is enough to see what
 * was done lately without the section becoming an archive.
 */
export default async function ProblemsSection() {
  const supabase = await createClient();
  const since = new Date(Date.now() - 30 * 86400000).toISOString();

  const [{ data: reports }, { data: staff }] = await Promise.all([
    supabase
      .from("problem_reports")
      .select("id, staff_id, screen, what, created_at, resolved_at, resolved_by, note")
      .or(`resolved_at.is.null,created_at.gte.${since}`)
      .order("created_at", { ascending: false })
      .limit(200),
    supabase.from("staff").select("id, name").eq("is_system", false),
  ]);

  const name = new Map((staff ?? []).map((s) => [s.id, s.name]));

  const rows: ProblemRow[] = (reports ?? []).map((r) => ({
    id: r.id,
    who: name.get(r.staff_id) ?? "—",
    screen: r.screen,
    what: r.what,
    created_at: r.created_at,
    resolved_at: r.resolved_at,
    resolved_by: r.resolved_by ? (name.get(r.resolved_by) ?? "") : "",
    note: r.note,
  }));

  return <ProblemList rows={rows} />;
}
