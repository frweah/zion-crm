import "server-only";
import type { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { CONTACT_KINDS, type HoursLine, type JobStanding, type LastContact, type ReportStanding } from "@/lib/client-dashboard-shape";

type Supabase = Awaited<ReturnType<typeof createClient>>;

/**
 * The client dashboard's reads, other than the board rows.
 *
 * The money on the dashboard comes from `readBoard` - the same rows Billing ›
 * Authorizations draws - so it is not read again here. What is read here is
 * the four things the board knows nothing about: the hours logged this month,
 * where this month's report stands, where the job search is, and when
 * somebody last spoke to the client.
 *
 * Every one of them is a question the old Activity tab answered by sending
 * somebody to another tab to look.
 */

/** The month the practice is in, as [first, last]. */
function thisMonth(): [string, string] {
  const day = today();
  const first = `${day.slice(0, 7)}-01`;
  const d = new Date(`${first}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(0);
  return [first, d.toISOString().slice(0, 10)];
}

/**
 * Hours logged this month, one line per service the client has an hourly
 * authorization for. A service authorized flat-fee has no line: there are no
 * hours to count against it, and a line reading zero would look like nobody
 * had worked rather than like the question does not apply.
 */
export async function readHours(supabase: Supabase, clientId: string): Promise<HoursLine[]> {
  const [from, to] = thisMonth();
  const { data: auths } = await supabase
    .from("authorizations")
    .select("id, service_type, rate_type")
    .eq("client_id", clientId)
    .eq("rate_type", "Hourly");

  const rows = (auths ?? []) as { id: string; service_type: string }[];
  if (!rows.length) return [];
  const serviceOf = new Map(rows.map((a) => [a.id, a.service_type]));

  const { data: entries } = await supabase
    .from("service_entries")
    .select("auth_id, hours, non_billable")
    .in("auth_id", [...serviceOf.keys()])
    .gte("date", from)
    .lte("date", to);

  const sum = new Map<string, number>();
  // Every service with an hourly authorization gets a line, even at nothing:
  // "no hours yet this month" is the answer somebody is looking for.
  for (const service of serviceOf.values()) sum.set(service, sum.get(service) ?? 0);
  for (const e of (entries ?? []) as { auth_id: string; hours: number | null }[]) {
    const service = serviceOf.get(e.auth_id);
    if (!service) continue;
    sum.set(service, (sum.get(service) ?? 0) + Number(e.hours ?? 0));
  }
  return [...sum.entries()]
    .map(([service, hours]) => ({ service, hours }))
    .sort((a, b) => a.service.localeCompare(b.service));
}

/** Where this month's report stands, if one has been raised. */
export async function readReport(supabase: Supabase, clientId: string): Promise<ReportStanding | null> {
  const [from] = thisMonth();
  const { data } = await supabase
    .from("client_reports")
    .select("status, due_on, sent_at")
    .eq("client_id", clientId)
    .eq("period", from)
    .order("created_at", { ascending: false })
    .limit(1);
  const row = ((data ?? []) as ReportStanding[])[0];
  return row ?? null;
}

/**
 * The statuses an application is finished in. Everything else is open, which
 * is the way round that survives somebody adding a status: a new one counts
 * as open and somebody notices, rather than disappearing from the count.
 */
const FINISHED = new Set(["Hired", "Declined by employer", "Client withdrew", "No response"]);

export async function readJobs(supabase: Supabase, clientId: string): Promise<JobStanding> {
  const day = today();
  const [{ data: matches }, { data: statuses }, { data: placements }] = await Promise.all([
    supabase
      .from("client_job_history")
      .select("match_id, status, status_rank, applied_on, interview_on, follow_up_on, employer_name, title, interview_time, updated_at")
      .eq("client_id", clientId)
      .order("status_rank")
      .order("updated_at", { ascending: false }),
    supabase
      .from("client_application_status")
      .select("match_id, status, at, reported_by_name")
      .eq("client_id", clientId)
      .order("at", { ascending: false })
      .limit(200),
    supabase
      .from("placements")
      .select("employer, title, start_date")
      .eq("client_id", clientId)
      .order("start_date", { ascending: false, nullsFirst: false })
      .limit(1),
  ]);

  type Match = {
    match_id: string;
    status: string;
    applied_on: string | null;
    interview_on: string | null;
    follow_up_on: string | null;
    employer_name: string | null;
    title: string | null;
    interview_time: string | null;
  };
  const rows = (matches ?? []) as Match[];
  const said = (statuses ?? []) as { match_id: string; status: string; at: string; reported_by_name: string | null }[];

  const open = rows.filter((r) => !FINISHED.has(r.status));
  const byStatus = new Map<string, number>();
  for (const r of open) byStatus.set(r.status, (byStatus.get(r.status) ?? 0) + 1);

  // Who reported a match's latest status: the owner the row carries.
  const owner = new Map<string, string>();
  for (const s of said) if (!owner.has(s.match_id)) owner.set(s.match_id, s.reported_by_name ?? "");

  const latest = said[0];
  const place = ((placements ?? []) as { employer: string | null; title: string | null; start_date: string | null }[])[0];

  // What is coming: an interview or a follow-up still ahead, soonest first.
  // Then, to fill the three, the applications that went out most recently -
  // which is what somebody asking "where are they" wants to read next.
  const ahead = open
    .flatMap((r) => [
      r.interview_on ? { r, when: r.interview_on, what: "Interview" } : null,
      r.follow_up_on ? { r, when: r.follow_up_on, what: "Follow up" } : null,
    ])
    .filter((x): x is { r: Match; when: string; what: string } => Boolean(x) && x!.when >= day)
    .sort((a, b) => a.when.localeCompare(b.when));

  const applied = open
    .filter((r) => r.applied_on && !ahead.some((a) => a.r.match_id === r.match_id))
    .sort((a, b) => (b.applied_on ?? "").localeCompare(a.applied_on ?? ""))
    .map((r) => ({ r, when: r.applied_on as string, what: "Applied" }));

  const next = [...ahead, ...applied].slice(0, 3).map(({ r, when, what }) => ({
    match_id: r.match_id,
    status: what,
    employer: r.employer_name ?? "an employer",
    title: r.title ?? "",
    when,
    detail: [r.title, what === "Interview" && r.interview_time ? r.interview_time : null]
      .filter(Boolean)
      .join(" · "),
    who: owner.get(r.match_id) ?? "",
  }));

  return {
    status: latest?.status ?? null,
    since: latest?.at ? latest.at.slice(0, 10) : null,
    open: open.length,
    byStatus: [...byStatus.entries()]
      .map(([status, count]) => ({ status, count }))
      .sort((a, b) => b.count - a.count || a.status.localeCompare(b.status)),
    lastPlacement: place
      ? { employer: place.employer ?? "", title: place.title ?? "", start_date: place.start_date }
      : null,
    next,
  };
}

/** When somebody last reached the client, and how. */
export async function readLastContact(supabase: Supabase, clientId: string): Promise<LastContact> {
  const { data } = await supabase
    .from("client_activity")
    .select("at, kind")
    .eq("client_id", clientId)
    .in("kind", Object.keys(CONTACT_KINDS))
    .order("at", { ascending: false })
    .limit(1);
  const row = ((data ?? []) as { at: string; kind: string }[])[0];
  return row ? { at: row.at, channel: CONTACT_KINDS[row.kind] ?? row.kind.toLowerCase() } : null;
}
