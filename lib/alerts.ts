import "server-only";
import { createClient } from "@/lib/supabase/server";
import { today, daysBetween } from "@/lib/constants";
import type { Role } from "@/lib/roles";

/**
 * The alert rules from the prototype, evaluated against the live record.
 *
 * These run when someone opens the app. Phase 5 moves them server-side on a
 * schedule so they fire even when nobody is logged in — the rules themselves
 * are written here so that move is a change of trigger, not of logic.
 */
export type Alert = {
  level: "bad" | "warn";
  text: string;
  roles: string[];
  href?: string;
};

function monthOf(d: string): string {
  return d.slice(0, 7);
}

/** The calendar month before the one containing `date`. */
function previousMonth(date: string): string {
  const d = new Date(date + "T00:00:00");
  d.setDate(0);
  return d.toISOString().slice(0, 7);
}

export async function buildAlerts(role: Role): Promise<Alert[]> {
  const supabase = await createClient();
  const now = today();

  const [
    authsResult,
    entriesResult,
    invoicesResult,
    tasksResult,
    contactsResult,
    clientsResult,
    staffResult,
    templatesResult,
    formsResult,
    notesResult,
  ] = await Promise.all([
    supabase
      .from("authorizations")
      .select("id, client_id, number, service_type, total_hours, carried_used, end_date, status")
      .eq("status", "Open"),
    supabase.from("service_entries").select("auth_id, date, hours, non_billable"),
    supabase.from("invoices").select("id, number, date, status"),
    supabase.from("tasks").select("id, title, due, status, assigned_staff_id").eq("status", "Open"),
    supabase
      .from("contact_log")
      .select("id, counselor_id, topic, follow_up, follow_up_done, staff_id")
      .not("follow_up", "is", null)
      .eq("follow_up_done", false),
    supabase.from("clients").select("id, name"),
    supabase.from("staff").select("id, role"),
    supabase.from("form_templates").select("id, usor, services, monthly, required_for_billing"),
    supabase.from("forms").select("auth_id, template_id, month, status"),
    supabase.from("notes").select("client_id, at, type"),
  ]);

  const auths = authsResult.data ?? [];
  const entries = entriesResult.data ?? [];
  const invoices = invoicesResult.data ?? [];
  const tasks = tasksResult.data ?? [];
  const contacts = contactsResult.data ?? [];
  const clients = clientsResult.data ?? [];
  const staff = staffResult.data ?? [];
  const templates = templatesResult.data ?? [];
  const forms = formsResult.data ?? [];
  const notes = notesResult.data ?? [];

  const clientName = new Map(clients.map((c) => [c.id, c.name]));
  const roleOfStaff = new Map(staff.map((s) => [s.id, s.role]));

  const used = new Map<string, number>();
  for (const a of auths) used.set(a.id, Number(a.carried_used ?? 0));
  for (const e of entries) {
    if (e.non_billable) continue;
    if (!used.has(e.auth_id)) continue;
    used.set(e.auth_id, (used.get(e.auth_id) ?? 0) + Number(e.hours));
  }

  const out: Alert[] = [];

  // ── authorizations: hours exhausted or nearly so ──────────
  for (const a of auths) {
    const label = `${a.number || a.service_type} (${a.service_type})`;

    if (a.total_hours != null) {
      const remaining = Number(a.total_hours) - (used.get(a.id) ?? 0);
      if (remaining <= 0) {
        out.push({
          level: "bad",
          text: `${label} has no hours left — request additional hours before more service.`,
          roles: ["Admin", "Billing", "Job Search"],
          href: `/clients/${a.client_id}?tab=authorizations`,
        });
      } else if (remaining <= Number(a.total_hours) * 0.1) {
        out.push({
          level: "warn",
          text: `${label} is under 10% remaining (${remaining} hrs).`,
          roles: ["Admin", "Billing"],
          href: `/clients/${a.client_id}?tab=authorizations`,
        });
      }
    }

    if (a.end_date) {
      const days = daysBetween(now, a.end_date);
      if (days >= 0 && days <= 14) {
        out.push({
          level: "warn",
          text: `${a.number || a.service_type} ends ${a.end_date} — unbilled work after that date will not be paid.`,
          roles: ["Admin", "Billing"],
          href: `/clients/${a.client_id}?tab=authorizations`,
        });
      }
    }
  }

  // ── invoices sent and unpaid ──────────────────────────────
  for (const i of invoices) {
    if (i.status !== "Sent") continue;
    const days = daysBetween(i.date, now);
    if (days >= 30) {
      out.push({
        level: days >= 90 ? "bad" : "warn",
        text: `Invoice ${i.number} unpaid ${days} days.`,
        roles: ["Admin", "Billing"],
        href: "/billing?tab=invoices",
      });
    }
  }

  // ── overdue tasks ─────────────────────────────────────────
  for (const t of tasks) {
    if (!t.due || t.due >= now) continue;
    const owner = t.assigned_staff_id ? roleOfStaff.get(t.assigned_staff_id) : undefined;
    out.push({
      level: "warn",
      text: `Overdue task: ${t.title}`,
      roles: ["Admin", ...(owner ? [owner] : [])],
      href: "/tasks",
    });
  }

  // ── monthly USOR reports, due by the 15th ─────────────────
  if (Number(now.slice(8, 10)) <= 15) {
    const lastMonth = previousMonth(now);
    const monthlyServices = ["Job Coaching", "Job Development", "Job Development + HQ Indicator"];
    const activityTypes = ["Job search", "Application submitted", "Interview", "Employer contact"];

    for (const a of auths) {
      if (!monthlyServices.includes(a.service_type)) continue;

      const hadActivity =
        entries.some((e) => e.auth_id === a.id && monthOf(e.date) === lastMonth) ||
        notes.some(
          (n) =>
            n.client_id === a.client_id &&
            monthOf(n.at) === lastMonth &&
            activityTypes.includes(n.type),
        );
      if (!hadActivity) continue;

      const missing = templates.filter(
        (t) =>
          t.monthly &&
          t.required_for_billing &&
          t.services.includes(a.service_type) &&
          !forms.some(
            (f) =>
              f.auth_id === a.id &&
              f.template_id === t.id &&
              f.month === lastMonth &&
              f.status !== "Draft",
          ),
      );

      if (missing.length > 0) {
        out.push({
          level: "warn",
          text: `${missing.map((t) => t.usor).join(" + ")} for ${lastMonth} due by the 15th — ${
            clientName.get(a.client_id) ?? "client"
          } (${a.number || a.service_type})`,
          roles: ["Admin", "Billing", "Job Search"],
          href: `/clients/${a.client_id}?tab=forms`,
        });
      }
    }
  }

  // ── counselor follow-ups now due ──────────────────────────
  for (const c of contacts) {
    if (!c.follow_up || c.follow_up > now) continue;
    const owner = c.staff_id ? roleOfStaff.get(c.staff_id) : undefined;
    out.push({
      level: "warn",
      text: `Counselor follow-up due: ${c.topic}`,
      roles: ["Admin", ...(owner ? [owner] : [])],
      href: "/counselors",
    });
  }

  return out.filter((a) => a.roles.includes(role));
}
