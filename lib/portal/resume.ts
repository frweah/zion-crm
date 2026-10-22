/**
 * The resume builder's data, and the two files drawn from it (portal brief,
 * section 4).
 *
 * The shape is shared by the portal's wizard (in the browser) and by the
 * server that saves it and draws the files. Whatever arrives from a browser
 * goes through cleanResume first: unknown keys dropped, every string trimmed
 * and capped, every list capped. Nothing is added that the client did not
 * type - the files are laid out from these fields and nothing else.
 */

export type ResumeJob = {
  employer: string;
  title: string;
  city: string;
  start: string; // YYYY-MM, or ""
  end: string; // YYYY-MM, or "" when still working there
  current: boolean;
  duties: string;
};

export type ResumeSchool = { school: string; what: string; year: string };
export type ResumeCert = { name: string; year: string };
export type ResumeVolunteer = { org: string; role: string; duties: string };

export type ResumeData = {
  contact: { name: string; phone: string; email: string; city: string };
  noJobs: boolean;
  jobs: ResumeJob[];
  education: ResumeSchool[];
  certs: ResumeCert[];
  skills: string[];
  volunteer: ResumeVolunteer[];
  summary: string;
};

export const EMPTY_JOB: ResumeJob = { employer: "", title: "", city: "", start: "", end: "", current: false, duties: "" };

export function emptyResume(): ResumeData {
  return {
    contact: { name: "", phone: "", email: "", city: "" },
    noJobs: false,
    jobs: [],
    education: [],
    certs: [],
    skills: [],
    volunteer: [],
    summary: "",
  };
}

/** The steps, in order. One screen each. */
export const RESUME_STEPS = [
  "Contact details",
  "Most recent job",
  "Earlier jobs",
  "Education and training",
  "Certificates and licenses",
  "Skills",
  "Volunteer work",
  "Summary",
  "Check and finish",
] as const;

/** Skills to tick, so nobody faces an empty box. They can add their own. */
export const SKILL_IDEAS = [
  "Customer service",
  "Cleaning and janitorial",
  "Stocking shelves",
  "Cash register",
  "Food preparation",
  "Following safety rules",
  "Working on a team",
  "Showing up on time",
  "Lifting and moving items",
  "Data entry",
  "Microsoft Word",
  "Answering phones",
  "Driving (valid license)",
  "Forklift",
  "Childcare",
  "Spanish",
];

/** Plain summaries to start from. Each is edited before it is used. */
export const SUMMARY_IDEAS = [
  "Reliable and hard-working, with experience in customer service. I show up on time and I am ready to learn.",
  "Dependable worker who takes pride in doing a job well. I work well on a team and follow directions carefully.",
  "Looking for my first job. I am eager to learn, friendly with people, and I take responsibility for my work.",
  "Experienced in warehouse and stocking work. Safe, steady and comfortable with physical tasks.",
];

const str = (v: unknown, max: number): string => (typeof v === "string" ? v.replace(/\s+$/g, "").slice(0, max) : "");
const line = (v: unknown, max: number): string => str(v, max).replace(/[\r\n]+/g, " ").trim();
const month = (v: unknown): string => (typeof v === "string" && /^\d{4}-(0[1-9]|1[0-2])$/.test(v) ? v : "");
const year = (v: unknown): string => (typeof v === "string" && /^(19|20)\d{2}$/.test(v.trim()) ? v.trim() : "");
const list = <T>(v: unknown, max: number, each: (x: Record<string, unknown>) => T): T[] =>
  Array.isArray(v) ? v.slice(0, max).filter((x) => x && typeof x === "object").map((x) => each(x as Record<string, unknown>)) : [];

export function cleanResume(input: unknown): ResumeData {
  const o = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const c = (o.contact && typeof o.contact === "object" ? o.contact : {}) as Record<string, unknown>;
  return {
    contact: { name: line(c.name, 80), phone: line(c.phone, 30), email: line(c.email, 120), city: line(c.city, 80) },
    noJobs: o.noJobs === true,
    jobs: list(o.jobs, 8, (j) => ({
      employer: line(j.employer, 100),
      title: line(j.title, 100),
      city: line(j.city, 80),
      start: month(j.start),
      end: j.current === true ? "" : month(j.end),
      current: j.current === true,
      duties: str(j.duties, 800),
    })),
    education: list(o.education, 6, (e) => ({ school: line(e.school, 120), what: line(e.what, 120), year: year(e.year) })),
    certs: list(o.certs, 10, (e) => ({ name: line(e.name, 120), year: year(e.year) })),
    skills: Array.isArray(o.skills)
      ? [...new Set(o.skills.slice(0, 30).map((s) => line(s, 60)).filter(Boolean))]
      : [],
    volunteer: list(o.volunteer, 5, (v) => ({ org: line(v.org, 100), role: line(v.role, 100), duties: str(v.duties, 600) })),
    summary: str(o.summary, 600).trim(),
  };
}

/** A job counts once it names at least the employer or the title. */
const real = (j: ResumeJob) => Boolean(j.employer || j.title);

/** What stops the resume being finished, in the client's words. */
export function resumeProblems(d: ResumeData): string[] {
  const out: string[] = [];
  if (!d.contact.name) out.push("Add your name on the Contact details step.");
  if (!d.contact.phone && !d.contact.email) out.push("Add a phone number or an email address, so employers can reach you.");
  if (!d.noJobs && !d.jobs.some(real)) out.push("Add your most recent job, or choose \"I have not had a job yet\".");
  if (d.noJobs && d.skills.length === 0 && d.education.length === 0 && d.volunteer.length === 0) {
    out.push("With no jobs yet, add some skills, training or volunteer work.");
  }
  return out;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export function monthText(m: string): string {
  if (!m) return "";
  const [y, mm] = m.split("-");
  return `${MONTHS[Number(mm) - 1]} ${y}`;
}
export function datesText(j: ResumeJob): string {
  const start = monthText(j.start);
  const end = j.current ? "Present" : monthText(j.end);
  return start && end ? `${start} – ${end}` : start || end;
}

/** Duties as bullet lines: one per line typed, leading dashes dropped. */
export function bullets(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((l) => l.replace(/^\s*[-•*]\s*/, "").trim())
    .filter(Boolean);
}

/** The sections in the order they print. Jobs lead; with none, skills lead. */
export type Section =
  | { kind: "summary" }
  | { kind: "jobs" }
  | { kind: "skills" }
  | { kind: "education" }
  | { kind: "certs" }
  | { kind: "volunteer" };

export function sectionOrder(d: ResumeData): Section["kind"][] {
  const jobs = d.jobs.filter(real);
  const has = {
    summary: Boolean(d.summary),
    jobs: !d.noJobs && jobs.length > 0,
    skills: d.skills.length > 0,
    education: d.education.some((e) => e.school || e.what),
    certs: d.certs.some((c) => c.name),
    volunteer: d.volunteer.some((v) => v.org || v.role),
  };
  const order: Section["kind"][] = has.jobs
    ? ["summary", "jobs", "skills", "education", "certs", "volunteer"]
    : ["summary", "skills", "education", "volunteer", "certs"];
  return order.filter((k) => has[k]);
}

export const SECTION_TITLE: Record<Section["kind"], string> = {
  summary: "Summary",
  jobs: "Work experience",
  skills: "Skills",
  education: "Education and training",
  certs: "Certificates and licenses",
  volunteer: "Volunteer experience",
};

export function realJobs(d: ResumeData): ResumeJob[] {
  return d.noJobs ? [] : d.jobs.filter(real);
}
