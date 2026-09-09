import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { today } from "@/lib/constants";

/**
 * The five things that might need somebody today.
 *
 * Counted here and listed on /needs from the same queries, so a counter can
 * never disagree with the list it opens — which is the way this sort of
 * dashboard usually goes wrong.
 *
 * "Mine" means assigned to me, unless I am Admin, in which case it means
 * everybody's. That matches how tasks already work rather than inventing a
 * second rule.
 */

export const NEEDS = [
  { key: "tasks", label: "Tasks due" },
  { key: "interviews", label: "Interviews" },
  { key: "followups", label: "Follow-ups due" },
  { key: "inactive", label: "Inactive clients" },
  { key: "paperwork", label: "Missing paperwork" },
] as const;

export type NeedKey = (typeof NEEDS)[number]["key"];

export type NeedRow = {
  id: string;
  title: string;
  detail: string;
  when: string | null;
  href: string;
};

const INACTIVE_DAYS = 30;
const INTERVIEW_DAYS = 7;

function addDays(iso: string, days: number): string {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export async function loadNeed(
  supabase: SupabaseClient<Database>,
  key: NeedKey,
  me: { id: string; role: string },
): Promise<NeedRow[]> {
  const now = today();
  const mine = me.role !== "Admin";

  if (key === "tasks") {
    let q = supabase
      .from("tasks")
      .select("id, title, due, client_id, assigned_staff_id")
      .eq("status", "Open")
      .lte("due", now)
      .order("due");
    if (mine) q = q.eq("assigned_staff_id", me.id);

    const { data } = await q;
    return (data ?? []).map((t) => ({
      id: t.id,
      title: t.title,
      detail: t.due && t.due < now ? "overdue" : "due today",
      when: t.due,
      href: t.client_id ? `/clients/${t.client_id}?tab=tasks` : "/tasks",
    }));
  }

  if (key === "interviews" || key === "followups") {
    const column = key === "interviews" ? "interview_on" : "follow_up_on";
    let q = supabase
      .from("client_job_history")
      .select(`match_id, client_id, employer_name, title, ${column}`)
      .not(column, "is", null);

    q =
      key === "interviews"
        ? q.gte(column, now).lte(column, addDays(now, INTERVIEW_DAYS))
        : q.lte(column, now);

    const { data } = await q.order(column);
    const rows = (data ?? []) as unknown as Record<string, string>[];

    // Whose client it is decides whose interview it is; the job itself does
    // not carry an owner.
    const clientIds = [...new Set(rows.map((r) => r.client_id))];
    const { data: clients } = await supabase
      .from("clients")
      .select("id, name, assigned_staff_id")
      .in("id", clientIds.length > 0 ? clientIds : ["00000000-0000-0000-0000-000000000000"]);
    const byId = new Map((clients ?? []).map((c) => [c.id, c]));

    return rows
      .filter((r) => !mine || byId.get(r.client_id)?.assigned_staff_id === me.id)
      .map((r) => ({
        id: r.match_id,
        title: `${byId.get(r.client_id)?.name ?? "A client"} — ${r.employer_name}`,
        detail: r.title,
        when: r[column],
        href: `/clients/${r.client_id}?tab=overview`,
      }));
  }

  if (key === "inactive") {
    const cutoff = addDays(now, -INACTIVE_DAYS);
    let q = supabase
      .from("clients")
      .select("id, name, stage, assigned_staff_id")
      .eq("status", "Active");
    if (mine) q = q.eq("assigned_staff_id", me.id);

    const { data: clients } = await q;
    const ids = (clients ?? []).map((c) => c.id);
    if (ids.length === 0) return [];

    const { data: activity } = await supabase
      .from("client_last_activity")
      .select("client_id, last_activity_at")
      .in("client_id", ids);
    const lastBy = new Map((activity ?? []).map((a) => [a.client_id, a.last_activity_at]));

    return (clients ?? [])
      .filter((c) => {
        const last = lastBy.get(c.id);
        return !last || last.slice(0, 10) < cutoff;
      })
      .map((c) => {
        const last = lastBy.get(c.id);
        return {
          id: c.id,
          title: c.name,
          detail: last
            ? `${c.stage} · nothing since ${last.slice(0, 10)}`
            : `${c.stage} · nothing recorded at all`,
          when: last ? last.slice(0, 10) : null,
          href: `/clients/${c.id}?tab=activity&days=0`,
        };
      })
      .sort((a, b) => (a.when ?? "").localeCompare(b.when ?? ""));
  }

  // paperwork
  const { data: outstanding } = await supabase
    .from("client_paperwork")
    .select("client_id, usor, form_name, month, hours_logged")
    .eq("state", "Missing");

  const rows = outstanding ?? [];
  const clientIds = [...new Set(rows.map((r) => r.client_id))].filter(Boolean) as string[];
  if (clientIds.length === 0) return [];

  let cq = supabase.from("clients").select("id, name, assigned_staff_id").in("id", clientIds);
  if (mine) cq = cq.eq("assigned_staff_id", me.id);
  const { data: clients } = await cq;
  const byId = new Map((clients ?? []).map((c) => [c.id, c]));

  // One line per client, listing what they are short of, rather than one line
  // per form — the question is "who needs chasing", not "how many forms".
  const grouped = new Map<string, string[]>();
  for (const r of rows) {
    const clientId = r.client_id;
    if (!clientId || !byId.has(clientId)) continue;
    const list = grouped.get(clientId) ?? [];
    list.push(r.month ? `${r.usor} (${r.month})` : (r.usor ?? "a form"));
    grouped.set(clientId, list);
  }

  return [...grouped.entries()].map(([clientId, forms]) => ({
    id: clientId,
    title: byId.get(clientId)?.name ?? "A client",
    detail: `${forms.length} form${forms.length === 1 ? "" : "s"} blocking billing — ${forms.join(", ")}`,
    when: null,
    href: `/clients/${clientId}?tab=forms`,
  }));
}

export async function countNeeds(
  supabase: SupabaseClient<Database>,
  me: { id: string; role: string },
): Promise<Record<NeedKey, number>> {
  const entries = await Promise.all(
    NEEDS.map(async (n) => [n.key, (await loadNeed(supabase, n.key, me)).length] as const),
  );
  return Object.fromEntries(entries) as Record<NeedKey, number>;
}
