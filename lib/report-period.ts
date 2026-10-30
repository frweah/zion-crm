import "server-only";
import { SERVICE_CODE } from "@/lib/constants";
import {
  addDays,
  mondayOf,
  monthEndOf,
  monthStartOf,
  previousMonthOf,
  weeksAcross,
} from "@/lib/report-weeks";
import type { Database } from "@/lib/database.types";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  GENERAL,
  type LineKind,
  type PeriodContent,
  type ReportLine,
  type ReportSection,
} from "./report-shape.ts";

// The shape of a report moved to lib/report-shape.ts, which has no imports,
// so the renderer can be run by a check. Re-exported from here because this
// is where the rest of the codebase already asks for it.
export { GENERAL };
export type { LineKind, PeriodContent, ReportLine, ReportSection };

/**
 * A stretch of the record, read as sections.
 *
 * Both the weekly report and the monthly one are this: a period, a section
 * for each service the client was authorized for in it, and inside each
 * section the dated lines of what the record says happened. The weekly report
 * is a week of it, generated on the Monday after. The monthly report is the
 * weeks of it put end to end, which is the owner's amendment of 28 Oct 2026
 * and the reason this builder takes a range rather than a week: a month has
 * gaps where no weekly report was made, and those days are read here too
 * rather than left out.
 *
 * **Nothing is invented.** Every line names a row somebody wrote: an hour
 * logged, an appointment kept, a note made, a letter filed, an application
 * sent, a day closed, a placement dated. A service with an authorization and
 * nothing against it says so, which is the whole point of generating the
 * thing — an empty section is a question for the person who owns the week,
 * and a missing section is a question nobody is asked.
 */

/**
 * Who a report is written for, and the gate on what goes into it.
 *
 * `notes.visible_roles` defaults to these four. A note narrowed below them is
 * narrowed on purpose - the practice decided it is not for everybody - and
 * copying its words into a document that is going to be signed and posted to
 * a counselor would undo that decision quietly. So a narrowed note still
 * appears as a line, dated and named by its type, with its words left out and
 * counted in `withheld`. The gap is visible; the words are not.
 *
 * 34 CFR 361.38 is the rule underneath: what reaches a counselor is what the
 * service needed, not everything the practice happens to know.
 */
export const REPORT_ROLES = ["Admin", "Job Search", "Reports", "Billing"] as const;

const coversReportRoles = (roles: string[] | null): boolean =>
  REPORT_ROLES.every((r) => (roles ?? []).includes(r));

/**
 * The service a kind of activity belongs under.
 *
 * The brief names six sections - assessment, job development, job search,
 * life skills, placement, job coaching - and the authorizations name fifteen
 * services. These are the families that join them up: an application belongs
 * under job development because that is the authorization it is worked
 * against, and there is no "Job Search" service to put it under.
 *
 * A line is attributed to a family, and then to whichever service of that
 * family the client actually holds an authorization for in the period. If
 * they hold none, the line goes to General rather than nowhere - a report
 * that drops what it cannot classify is worse than one with a general
 * section, because the person reading it cannot tell that anything is gone.
 */
export type ServiceFamily = "assessment" | "development" | "placement" | "coaching" | "life";

const FAMILY_OF: Record<string, ServiceFamily> = {
  "WSA Tier 1": "assessment",
  "WSA Tier 2": "assessment",
  "HQ Indicator": "assessment",
  "Job Development": "development",
  "Job Development + HQ Indicator": "development",
  "Job Placement": "placement",
  "Job Placement (SE)": "placement",
  "Job Coaching": "coaching",
  "Follow-Along": "coaching",
  "Supported Employment": "coaching",
  "Life Skills": "life",
  "CRP Group Training": "life",
  "Job Readiness": "life",
  "Temporary Work Experience": "life",
};

/** The family a note's type speaks to, where its type says one at all. */
const FAMILY_OF_NOTE: Record<string, ServiceFamily> = {
  "Job search": "development",
  "Application submitted": "development",
  Interview: "development",
  "Employer contact": "development",
  "Coaching session": "coaching",
};

/**
 * The family a note's category speaks to.
 *
 * The category is the better answer and is asked first: it says which service
 * the note is about, where the type says what shape of contact it was. A
 * meeting can be about coaching or about life skills and the type cannot tell
 * them apart, which is why the column exists (0266).
 *
 * The type map above stays as the fallback for the notes written before the
 * column did, and goes when they are backfilled.
 *
 * Personal is not in this map and must not be. It is not a service, it is the
 * category that means "this is on the record because we need it and it is
 * nobody else's business", and `isPersonal` below is what keeps it out.
 */
const FAMILY_OF_CATEGORY: Record<string, ServiceFamily> = {
  "Job development": "development",
  "Job placement": "placement",
  "Job coaching": "coaching",
  "Job search": "development",
  Assessment: "assessment",
  "Life skills": "life",
};

/**
 * A note nobody outside the practice sees.
 *
 * Checked by category rather than by roles, because the two guards answer
 * different questions. The roles say who may read the note on the screen; this
 * says the note is not part of the account of a service, which is a different
 * claim and the one a report is making. A Personal note is not withheld from a
 * report - it is not in one, and it is not counted in `withheld` either,
 * because telling a counselor "two notes are not included here" about somebody's
 * housing is still telling them something.
 */
export const isPersonal = (category: string | null | undefined): boolean =>
  category === "Personal";


// Re-exported so a caller needs one import for "a period of the record" and
// not two. The arithmetic lives apart because check-reports.mjs runs it.
export { addDays, mondayOf, monthEndOf, monthStartOf, previousMonthOf, weeksAcross };

type Supabase = SupabaseClient<Database>;

const dayOf = (stamp: string | null): string => (stamp ?? "").slice(0, 10);

/**
 * A date as a reader wants it, for the inside of a sentence.
 *
 * Only for the standing lines, where a date has to sit in the prose rather
 * than in the renderer's date column. Noon UTC so a date-only string is not
 * dragged back a day by the machine's offset, which is the same trap
 * `lib/report-text.ts` sidesteps the same way.
 */
const day = (iso: string): string =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });

/**
 * The record between two dates, as sections.
 *
 * Takes the Supabase client rather than making one, because this runs two
 * ways: as the scheduler, which sees everything and is why `REPORT_ROLES`
 * above exists, and as a person asking to rebuild a week, where row-level
 * security has already taken out what they may not read.
 */
export async function buildPeriodContent(
  supabase: Supabase,
  clientId: string,
  from: string,
  to: string,
): Promise<PeriodContent> {
  const inRange = (d: string | null): boolean => Boolean(d && d >= from && d <= to);

  const { data: client } = await supabase
    .from("clients")
    .select("id, wsa_tier, wsa_completed, wsa_submitted")
    .eq("id", clientId)
    .maybeSingle();

  // The authorizations whose dates overlap the period. Closed ones are left
  // out; Paid ones are not, because a service that has been billed is still
  // the service that was delivered in the month being reported on.
  const { data: authRows } = await supabase
    .from("authorizations")
    .select("id, service_type, start_date, end_date, status")
    .eq("client_id", clientId)
    .neq("status", "Closed");

  // A date the record does not have is an end the service does not have.
  //
  // This was `start_date <= to` in the query and it was wrong, measured
  // against the practice on 28 Oct 2026: twelve of the forty-five
  // authorizations on Active clients have no start date, so asking the
  // database for the ones starting before the month quietly dropped a quarter
  // of them. Eleven clients hold a service open in October; the first version
  // of this found four, and the nine months of coaching the other seven were
  // getting would have been reported as no service at all.
  //
  // Dates arrive off a scanned authorization (`dates_from_ocr`), so a gap is
  // ordinary rather than a fault. A missing bound is treated as open in that
  // direction: the service is in this period unless the record says it had
  // finished or had not begun.
  const auths = (authRows ?? []).filter(
    (a) => (!a.start_date || a.start_date <= to) && (!a.end_date || a.end_date >= from),
  );
  const authById = new Map(auths.map((a) => [a.id, a]));
  const authIds = auths.map((a) => a.id);

  // One section per service held, in the order the work happens, and a
  // General section that only survives if something lands in it.
  const order = ["assessment", "development", "placement", "coaching", "life"] as const;
  const services: string[] = [];
  for (const family of order) {
    for (const a of auths) {
      if (FAMILY_OF[a.service_type] === family && !services.includes(a.service_type)) {
        services.push(a.service_type);
      }
    }
  }
  for (const a of auths) {
    if (!FAMILY_OF[a.service_type] && !services.includes(a.service_type)) {
      services.push(a.service_type);
    }
  }

  const sections = new Map<string, ReportSection>();
  for (const service of services) {
    sections.set(service, { service, code: SERVICE_CODE[service] ?? "—", lines: [] });
  }
  sections.set(GENERAL, { service: GENERAL, code: "—", lines: [] });

  /** The section a family's line belongs in: its own, or General. */
  const sectionFor = (family: ServiceFamily | null): ReportSection => {
    if (family) {
      const held = services.find((s) => FAMILY_OF[s] === family);
      if (held) return sections.get(held)!;
    }
    return sections.get(GENERAL)!;
  };

  const put = (family: ServiceFamily | null, line: ReportLine) => {
    sectionFor(family).lines.push(line);
  };

  const [
    entriesResult,
    notesResult,
    eventsResult,
    mailResult,
    jobsResult,
    placementsResult,
    contactsResult,
    daysResult,
  ] = await Promise.all([
    // Billable and non-billable service hours, which is what the counselor is
    // being told about. Staff hours in `work_sessions` are payroll and are not
    // in a report to a counselor.
    authIds.length
      ? supabase
          .from("service_entries")
          .select("auth_id, date, hours, non_billable, notes")
          .in("auth_id", authIds)
          .gte("date", from)
          .lte("date", to)
          .order("date")
      : Promise.resolve({ data: [] as never[] }),
    supabase
      .from("notes")
      .select("at, type, text, staff_name, visible_roles, category")
      .eq("client_id", clientId)
      .gte("at", from)
      .lte("at", to)
      .order("at"),
    supabase
      .from("calendar_events")
      .select("kind, title, starts_at, location")
      .eq("client_id", clientId)
      .gte("starts_at", `${from}T00:00:00Z`)
      .lte("starts_at", `${to}T23:59:59Z`)
      .order("starts_at"),
    // Filed mail, by its subject. No message body is stored anywhere in this
    // system and a report is not where that changes.
    supabase
      .from("mail_log")
      .select("subject, sent_at, direction, counterpart_email, restricted, filed_at")
      .eq("client_id", clientId)
      .not("filed_at", "is", null)
      .gte("sent_at", `${from}T00:00:00Z`)
      .lte("sent_at", `${to}T23:59:59Z`)
      .order("sent_at"),
    // Where each application got to, in the period (0270). Read from the
    // history rather than from applied_on / interview_on / decided_on, which
    // between them covered three of the nine things that happen - so an
    // employer answering, or answering nothing at all, was in no report.
    supabase
      .from("client_application_status")
      .select("employer_name, title, status, at, note")
      .eq("client_id", clientId)
      .gte("at", from)
      .lte("at", to)
      .order("at")
      .limit(400),
    supabase
      .from("placements")
      .select("employer, title, start_date, check30, check60, check90, stability_on")
      .eq("client_id", clientId)
      .limit(50),
    supabase
      .from("contact_log")
      .select("date, method, topic, outcome")
      .eq("client_id", clientId)
      .gte("date", from)
      .lte("date", to)
      .order("date"),
    supabase
      .from("staff_day_lines")
      .select("status, description, notes, staff_days!inner(day, staff_id)")
      .eq("client_id", clientId)
      .gte("staff_days.day", from)
      .lte("staff_days.day", to)
      .limit(500),
  ]);

  let withheld = 0;
  let hours = 0;

  for (const e of entriesResult.data ?? []) {
    const service = authById.get(e.auth_id)?.service_type ?? "";
    const family = FAMILY_OF[service] ?? null;
    if (!e.non_billable) hours += Number(e.hours);
    put(family, {
      on: e.date,
      kind: "hours",
      hours: e.non_billable ? 0 : Number(e.hours),
      text:
        `${e.hours} hr${e.non_billable ? " (non-billable)" : ""}` +
        (e.notes ? ` — ${e.notes}` : ""),
    });
  }

  for (const n of notesResult.data ?? []) {
    // Before anything else, and before `withheld` is touched. A Personal note
    // is not in the report and is not counted as missing from it either.
    if (isPersonal(n.category)) continue;

    const type = n.type || "General";
    const open = coversReportRoles(n.visible_roles);
    if (!open) withheld++;
    // The category first, because it says which service the note is about. The
    // type is the fallback for notes written before the column existed.
    const family = (n.category ? FAMILY_OF_CATEGORY[n.category] : undefined) ?? FAMILY_OF_NOTE[type] ?? null;
    put(family, {
      on: n.at,
      kind: "note",
      text: open
        ? `${type} — ${n.text}`
        : `${type} — note held back, on the client record`,
    });
  }

  for (const ev of eventsResult.data ?? []) {
    put(null, {
      on: dayOf(ev.starts_at),
      kind: "appointment",
      text:
        `${ev.kind || "Appointment"} — ${ev.title || "no title"}` +
        (ev.location ? ` (${ev.location})` : ""),
    });
  }

  for (const m of mailResult.data ?? []) {
    if (m.restricted) {
      withheld++;
      continue;
    }
    put(null, {
      on: dayOf(m.sent_at),
      kind: "mail",
      text: `${m.direction === "in" ? "Received" : "Sent"} — ${m.subject || "no subject"}`,
    });
  }

  for (const j of jobsResult.data ?? []) {
    // A view's columns all read as nullable, and `at` is not null on the table
    // underneath. Skipped rather than dated today, which would put an entry in
    // a month it did not happen in.
    if (!inRange(j.at)) continue;
    const where = `${j.employer_name}${j.title ? ` — ${j.title}` : ""}`;
    put("development", {
      on: j.at!,
      kind: "job",
      text: `${j.status} — ${where}${j.note ? ` — ${j.note}` : ""}`,
    });
  }

  for (const p of placementsResult.data ?? []) {
    const where = `${p.employer || "employer not recorded"}${p.title ? ` — ${p.title}` : ""}`;
    if (inRange(p.start_date)) {
      put("placement", { on: p.start_date!, kind: "placement", text: `Started — ${where}` });
    }
    if (inRange(p.stability_on)) {
      put("placement", { on: p.stability_on!, kind: "placement", text: `Stable — ${where}` });
    }
    for (const [label, on] of [
      ["30-day check", p.check30],
      ["60-day check", p.check60],
      ["90-day check", p.check90],
    ] as const) {
      if (inRange(on)) {
        put("coaching", { on: on!, kind: "placement", text: `${label} — ${where}` });
      }
    }

    // Where the placement stands, whatever month this report covers.
    //
    // Everything above is dated inside the period, which is right for
    // activity and wrong for this: a counselor reading November about somebody
    // hired in September was being told nothing about the hire, and retention
    // is the one fact a placement report exists to carry. So each placement
    // also contributes one line saying when it started and which checks have
    // been recorded - undated, because it is where things stand rather than
    // something that happened this month.
    //
    // Only dates the record actually holds. A check that has not happened is
    // not given a due date here: the practice's own screens work out when one
    // is due from the start date, and a report that printed a date nobody
    // recorded would be a report making a commitment on somebody's behalf.
    if (p.start_date) {
      const reached = (
        [
          ["30-day check", p.check30],
          ["60-day check", p.check60],
          ["90-day check", p.check90],
          ["stable since", p.stability_on],
        ] as const
      ).filter(([, on]) => Boolean(on));

      put("placement", {
        // Dated at the end of the period, because what it says is where things
        // stand as at then. `standing` is what stops the renderer printing
        // that date as though the hire happened on it.
        on: to,
        standing: true,
        kind: "placement",
        text:
          `Placed ${day(p.start_date)} — ${where}` +
          (reached.length
            ? `. ${reached.map(([label, on]) => `${label} ${day(on!)}`).join(", ")}`
            : ". No retention check recorded yet"),
      });
    }
  }

  for (const c of contactsResult.data ?? []) {
    put(null, {
      on: c.date,
      kind: "contact",
      text: `${c.method} — ${c.topic}${c.outcome ? ` — ${c.outcome}` : ""}`,
    });
  }

  for (const line of (daysResult.data ?? []) as unknown as {
    status: string;
    description: string;
    notes: string | null;
    staff_days: { day: string };
  }[]) {
    put(null, {
      on: line.staff_days.day,
      kind: "day",
      text: `${line.status} — ${line.description}${line.notes ? ` — ${line.notes}` : ""}`,
    });
  }

  // The WSA has no service entry of its own: the dates are on the client.
  const tier = client?.wsa_tier === 2 ? "WSA Tier 2" : "WSA Tier 1";
  if (inRange(client?.wsa_completed ?? null)) {
    put("assessment", {
      on: client!.wsa_completed!,
      kind: "assessment",
      text: `${tier} completed`,
    });
  }
  if (inRange(client?.wsa_submitted ?? null)) {
    put("assessment", {
      on: client!.wsa_submitted!,
      kind: "assessment",
      text: `${tier} sent to the counselor`,
    });
  }

  const out: ReportSection[] = [];
  for (const section of sections.values()) {
    section.lines.sort((a, b) => (a.on < b.on ? -1 : a.on > b.on ? 1 : 0));
    // A service held is a section whether or not anything happened under it.
    // General is only there when something is in it.
    if (section.service === GENERAL && !section.lines.length) continue;
    out.push(section);
  }

  return { from, to, sections: out, withheld, hours: Math.round(hours * 100) / 100 };
}
