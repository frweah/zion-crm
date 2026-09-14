/**
 * What a document's name says, and what to do with the document.
 *
 * The client folders are named with care even when the PDF inside is a scan
 * nothing can read: "19 V0000910 JC" is a job coaching authorization,
 * "Job development invoice 19 V0000908" is what was billed against one,
 * "Jan [USOR96]" is January's job development report. So the name is read
 * first and the PDF's text and form fields fill in what it leaves out.
 *
 * Three kinds of name, as the owner described them:
 *
 *   An authorization - a V-number and a service code. The numbers in front
 *   (06, 10, 17, 19, 20) and counselor initials (KL_, IO_, BB_) mean nothing.
 *   It goes on the authorization with that number; one not on file waits in
 *   the inbox to be confirmed.
 *
 *   An invoice - "invoice", "bill", "billing". It goes on its authorization,
 *   which then shows it as billed: paid if a payment is on file, else
 *   outstanding. No invoice row is made - a scan carries no amount.
 *
 *   A narrative - a monthly report, a summary, an assessment, a resume. It
 *   becomes a note of the matching activity type, dated from the document.
 *   Monthly reports are dated by the month they cover, not the day they were
 *   saved. The file's saved date is the last resort, and the note says so.
 *
 * Service codes, as confirmed: JC job coaching; JD, JS job development; HQI
 * the HQ indicator; JP, PL, CIE job placement; CE customized employment, which
 * is Job Placement (SE); WSA and discovery the work strategy assessment.
 *
 * Nothing here decides silently between two answers. An invoice that could be
 * for either of two authorizations is left for a person to pick.
 *
 * No imports, so scripts/check-filename-rules.mjs can run it directly.
 */

export type NoteType =
  | "General"
  | "Meeting"
  | "Job search"
  | "Application submitted"
  | "Employer contact"
  | "Coaching session"
  | "Counselor contact";

export type Category = "Signed USOR form" | "Authorization" | "Invoice" | "Other";

export type DatedFrom =
  | "Named in the file"
  | "Period covered"
  | "Read from the document"
  | "File date (fallback)";

export type Family =
  | "Job Coaching"
  | "Job Development"
  | "Job Placement"
  | "WSA"
  | "Life Skills"
  | "Job Readiness"
  | "Supported Employment";

export type NamePattern =
  | "Authorization"
  | "Invoice"
  | "Report"
  | "Resume"
  | "Billable hours form"
  | "Attach"
  | "Not a client document"
  | "Nothing in the name"
  | "Service only"
  | "Unmatched";

export type MonthRef = { month: number; year: number | null };

export type NameReading = {
  pattern: NamePattern;
  /** "V0000910" - digits only after the V, as written in the name. */
  vNumbers: string[];
  families: Family[];
  /** HQI in the name: the job development authorization carries the HQ indicator. */
  hqIndicator: boolean;
  /** JD, JS or job development in the name, as well as or instead of HQI. */
  jobDevelopmentNamed: boolean;
  /** CE, or SE with placement: Job Placement (SE). */
  supported: boolean;
  usor: string | null;
  noteType: NoteType | null;
  category: Category | null;
  /** USOR 94 and 98 are the restricted tier; a WSA or discovery document is one. */
  restricted: boolean;
  /** Dated by the month it covers. */
  periodic: boolean;
  label: string;
  exactDate: string | null;
  month: MonthRef | null;
  sentMonthDay: { month: number; day: number } | null;
};

export type AuthLite = {
  id: string;
  number: string;
  service_type: string;
  status: string;
  start_date: string | null;
  end_date: string | null;
};

// ── small helpers ────────────────────────────────────────────

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const MONTH_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];
const MONTH_WORD =
  /\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\b/gi;

const monthOf = (word: string) => MONTHS.indexOf(word.slice(0, 3).toLowerCase()) + 1;
const pad = (n: number) => String(n).padStart(2, "0");
const iso = (y: number, m: number, d: number) => `${y}-${pad(m)}-${pad(d)}`;
const lastDay = (y: number, m: number) => new Date(Date.UTC(y, m, 0)).getUTCDate();

function validDate(y: number, m: number, d: number): string | null {
  if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > lastDay(y, m)) return null;
  return iso(y, m, d);
}

const twoDigitYear = (yy: number) => (yy < 100 ? 2000 + yy : yy);

/** The year a month with no year belongs to: the latest one not after the file was saved. */
function inferYear(month: number, fileModified: string | null, today: string): number {
  const ref = fileModified ? new Date(fileModified) : new Date(`${today}T12:00:00Z`);
  const y = ref.getUTCFullYear();
  return month > ref.getUTCMonth() + 1 ? y - 1 : y;
}

/** Upper case, letters and digits, no leading V, no issue letter: V0000375C is 0000375. */
export function vKey(number: string): string {
  return String(number ?? "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .replace(/^V(?=\d)/, "")
    .replace(/(\d)[A-Z]$/, "$1");
}

export function familyOf(serviceType: string): Family | string {
  if (serviceType.startsWith("WSA")) return "WSA";
  if (serviceType.startsWith("Job Development") || serviceType === "HQ Indicator") return "Job Development";
  if (serviceType.startsWith("Job Placement")) return "Job Placement";
  return serviceType;
}

// ── reading the name ─────────────────────────────────────────

type Usor = { noteType: NoteType; label: string; periodic: boolean; restricted: boolean };

const USOR: Record<string, Usor> = {
  "60": { noteType: "Employer contact", label: "CIE job placement report (USOR 60)", periodic: false, restricted: false },
  "92": { noteType: "Meeting", label: "Initial job placement assessment (USOR 92)", periodic: false, restricted: false },
  "93": { noteType: "Coaching session", label: "Monthly job coaching report (USOR 93)", periodic: true, restricted: false },
  "94": { noteType: "Meeting", label: "Work strategy assessment (USOR 94)", periodic: false, restricted: true },
  "95": { noteType: "Coaching session", label: "Job coaching tracker (USOR 95)", periodic: true, restricted: false },
  "96": { noteType: "Job search", label: "Job development monthly report (USOR 96)", periodic: true, restricted: false },
  "98": { noteType: "Counselor contact", label: "Referral for CRP assessment (USOR 98)", periodic: false, restricted: true },
  "144": { noteType: "Employer contact", label: "USOR 144", periodic: false, restricted: false },
};

/** How a known USOR form is filed, for a document whose text names it. */
export function usorFiling(usor: string): Usor | null {
  return USOR[usor] ?? null;
}

const NARRATIVE: [RegExp, string][] = [
  [/monthly report/i, "Monthly report"],
  [/progress (report|form)/i, "Progress report"],
  [/summary of activities/i, "Summary of activities"],
  [/summary report/i, "Summary report"],
  [/comprehensive/i, "Comprehensive report"],
  [/job dev\w* (progress )?report/i, "Job development report"],
  [/employment report/i, "Employment report"],
  [/discovery/i, "Discovery"],
  [/asse?s+e?ment/i, "Assessment"],
  [/case note/i, "Case note"],
  [/incident/i, "Incident note"],
  [/eligib/i, "Eligibility letter"],
  [/award letter/i, "Award letter"],
  [/observation/i, "Observation report"],
  [/task list/i, "Daily task list"],
  [/job history/i, "Job history"],
  [/workbook/i, "Workbook"],
  [/\bplan\b/i, "Plan"],
  [/evaluation|outlook/i, "Evaluation"],
  [/guidelines/i, "Guidelines"],
  [/\bweek\b/i, "Week report"],
  [/summary/i, "Summary"],
  [/report/i, "Report"],
  [/review/i, "Review"],
  [/\bnotes?\b/i, "Notes"],
];

const JOB_POSTING = /custodian|maintenance worker|job posting|opening/i;
const EMPLOYER_DOC = /employer|emp info|offer letter/i;

function familiesIn(n: string): Family[] {
  const f = new Set<Family>();
  // A code may be glued to "auth": "JS JD JPauth".
  if (/\bJC(?=\b|auth)|job\s*co(?:a)?c?h|jobcoach/i.test(n)) f.add("Job Coaching");
  if (/\b(?:JD|JS)(?=\b|auth)|job\s*dev|jobdevelop|job\s*search|\bHQI\b|HQ\s*Indicator/i.test(n)) f.add("Job Development");
  if (/\b(?:JP|PL)(?=\b|auth)|placement|\bCIE\b|\bCE\b|customi[sz]ed employment/i.test(n)) f.add("Job Placement");
  if (/wsa\b|discovery/i.test(n)) f.add("WSA");
  if (/life\s*skills?/i.test(n)) f.add("Life Skills");
  if (/(?:job|work|workplace)\s*readiness/i.test(n)) f.add("Job Readiness");
  if (f.size === 0 && /supported employment/i.test(n)) f.add("Supported Employment");
  return [...f];
}

function usorInName(n: string): string | null {
  const m =
    n.match(/usor\s*#?-?\s*(\d{2,3})/i) ??
    n.match(/form\s*#?\s*(\d{2,3})\b/i) ??
    n.match(/\bCIE\s*(60)\b/i) ??
    n.match(/(?:^|\s)(60|92|93|94|95|96|98|148)(?=\s|$)/);
  return m ? m[1] : null;
}

type NameDates = Pick<NameReading, "exactDate" | "month" | "sentMonthDay">;

function datesInName(n: string): NameDates {
  let m: RegExpMatchArray | null;

  if ((m = n.match(/(20\d{2})(\d{2})(\d{2})(?!\d)/))) {
    const d = validDate(+m[1], +m[2], +m[3]);
    if (d) return { exactDate: d, month: null, sentMonthDay: null };
  }
  if ((m = n.match(/\b(\d{1,2})[ .-](\d{1,2})[ .-](20\d{2})\b/))) {
    const d = validDate(+m[3], +m[1], +m[2]);
    if (d) return { exactDate: d, month: null, sentMonthDay: null };
  }
  if ((m = n.match(/\b(\d{1,2})-(\d{1,2})-\s?(\d{2})\b/))) {
    const d = validDate(twoDigitYear(+m[3]), +m[1], +m[2]);
    if (d) return { exactDate: d, month: null, sentMonthDay: null };
  }
  // "sent 10-23" is the day it was sent, not October 2023.
  if ((m = n.match(/\bse[nb]t\s+(\d{1,2})-\s?(\d{1,2})\b/i)) && +m[1] <= 12 && +m[2] <= 31) {
    return { exactDate: null, month: null, sentMonthDay: { month: +m[1], day: +m[2] } };
  }
  if ((m = n.match(/(?:^|\s)(0[1-9]|1[0-2])-(2\d)(?=\s|$)/))) {
    return { exactDate: null, month: { month: +m[1], year: 2000 + +m[2] }, sentMonthDay: null };
  }

  const words = [...n.matchAll(MONTH_WORD)];
  if (words.length) {
    const month = monthOf(words[words.length - 1][1]);
    const y = n.match(/\b(20\d{2})\b/) ?? n.match(/'(\d{2})\b/);
    return { exactDate: null, month: { month, year: y ? twoDigitYear(+y[1]) : null }, sentMonthDay: null };
  }
  return { exactDate: null, month: null, sentMonthDay: null };
}

export function readFilename(filename: string, clientName = ""): NameReading {
  const raw = filename.replace(/\.pdf$/i, "").trim();
  // Counselor initials in front of a V-number mean nothing: "XY_v0000447".
  const n = raw.replace(/\b[A-Za-z]{2}_(?=[Vv]\d)/g, " ").replace(/_/g, " ").replace(/\s+/g, " ").trim();

  const vNumbers = [...new Set([...raw.matchAll(/(?:^|[^A-Za-z0-9]|[A-Za-z]{2}_)[Vv]-?(\d{6,7})(?!\d)/g)].map((x) => `V${x[1]}`))];
  const families = familiesIn(n);
  const hqIndicator = /\bHQI\b|HQ\s*Indicator/i.test(n);
  const supported = /\bCE\b|customi[sz]ed/i.test(n) || (/\bSE\b/.test(n) && /placement|\bJP\b|\bPL\b/i.test(n));
  const usor = usorInName(n);
  const dates = datesInName(n);

  // What is left once the client's own name and filler words are gone.
  const clientWords = clientName.toLowerCase().split(/[^a-z]+/).filter((w) => w.length >= 3);
  let residue = n.toLowerCase();
  for (const w of clientWords) residue = residue.split(w).join(" ");
  const bare = !/[a-z]{2,}/.test(residue.replace(/\b(file|pgs?|pic|scan|copy|sent|signed|doc|document)\b/g, " "));

  const base: NameReading = {
    pattern: "Unmatched",
    vNumbers,
    families,
    hqIndicator,
    jobDevelopmentNamed: /\b(?:JD|JS)(?=\b|auth)|job\s*dev|jobdevelop|job\s*search/i.test(n),
    supported,
    usor,
    noteType: null,
    category: null,
    restricted: false,
    periodic: false,
    label: "",
    ...dates,
  };
  const as = (patch: Partial<NameReading>): NameReading => ({ ...base, ...patch });

  if (/\breceipt\b|stamped file copy|business acknowledgement|entity number/i.test(n)) {
    return as({ pattern: "Not a client document", label: "Business filing paperwork" });
  }

  const scanner = /^\d{3,5} \d{3}$/.test(n) || /^\d+$/.test(n);
  const randomId = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(raw) || /^[A-Z0-9]{12,16}$/.test(raw);
  if (scanner || randomId) return as({ pattern: "Nothing in the name" });

  if (/\b148\b|crp billable|billable (hours|form)/i.test(n)) {
    return as({ pattern: "Billable hours form", category: "Signed USOR form", label: "CRP billable hours form (USOR 148)" });
  }
  if (/invoice|\bbill(?:s|ing|ed)?\b|\bhrs\b/i.test(n)) {
    return as({ pattern: "Invoice", category: "Invoice", label: "Invoice" });
  }
  if (/auth(?!or)|amendment/i.test(n) || (vNumbers.length > 0 && !usor)) {
    return as({ pattern: "Authorization", category: "Authorization", label: /amendment/i.test(n) ? "Authorization amendment" : "Authorization" });
  }
  if (/r[eé]sum/i.test(n)) {
    return as({ pattern: "Resume", category: "Other", noteType: "General", label: "Resume on file" });
  }

  if (usor && USOR[usor]) {
    const u = USOR[usor];
    const referral = usor === "94" && /referral/i.test(n);
    return as({
      pattern: "Report",
      category: "Signed USOR form",
      noteType: referral ? "Counselor contact" : u.noteType,
      label: referral ? "WSA referral (USOR 94)" : u.label,
      periodic: u.periodic,
      restricted: u.restricted,
    });
  }

  if (families.includes("WSA") && families.length === 1) {
    const referral = /referral/i.test(n);
    const discovery = /discovery/i.test(n);
    return as({
      pattern: "Report",
      category: discovery ? "Other" : "Signed USOR form",
      noteType: referral ? "Counselor contact" : "Meeting",
      label: referral ? "WSA referral (USOR 94)" : discovery ? "Discovery" : /notes|comments/i.test(n) ? "WSA notes" : "Work strategy assessment (USOR 94)",
      restricted: true,
    });
  }

  // A month and one service and nothing else: that month's report for it.
  if (dates.month && families.length === 1 && ["Job Coaching", "Job Development", "Life Skills"].includes(families[0])) {
    const f = families[0];
    return as({
      pattern: "Report",
      category: f === "Life Skills" ? "Other" : "Signed USOR form",
      noteType: f === "Job Development" ? "Job search" : "Coaching session",
      label: f === "Job Coaching" ? "Monthly job coaching report (USOR 93)" : f === "Job Development" ? "Job development monthly report (USOR 96)" : "Monthly life skills report",
      periodic: true,
    });
  }

  const narrative = NARRATIVE.find(([r]) => r.test(n));
  if (narrative) {
    const noteType: NoteType = /incident/i.test(n)
      ? "General"
      : /job coach|coaching|shelving|observation|\bweek\b|task list/i.test(n)
        ? "Coaching session"
        : /job dev|progress|summary of activities|job history|employment report|job search|outlook/i.test(n)
          ? "Job search"
          : /case note|eligib|award letter|\bvr\b/i.test(n)
            ? "Counselor contact"
            : /placement/i.test(n)
              ? "Employer contact"
              : "Meeting";
    const periodic = /monthly/i.test(n) || (Boolean(dates.month) && /report|progress|summary/i.test(n));
    return as({ pattern: "Report", category: "Other", noteType, label: narrative[1], periodic });
  }

  if (/application/i.test(n)) {
    return as({ pattern: "Report", category: "Other", noteType: "Application submitted", label: "Job application" });
  }
  if (JOB_POSTING.test(n)) {
    return as({ pattern: "Report", category: "Other", noteType: "Job search", label: "Job posting" });
  }
  if (EMPLOYER_DOC.test(n)) {
    return as({ pattern: "Report", category: "Other", noteType: "Employer contact", label: "Employer document" });
  }
  if (/certificat|licen[cs]e|\bcerts?\b/i.test(n)) {
    return as({ pattern: "Attach", category: "Other", label: "Certificate or licence" });
  }

  if (bare || /noreply@/i.test(raw)) return as({ pattern: "Nothing in the name" });
  if (families.length) return as({ pattern: "Service only" });
  return base;
}

// ── dates ────────────────────────────────────────────────────

function dateIn(value: string): string | null {
  let m: RegExpMatchArray | null;
  if ((m = value.match(/\b(20\d{2})-(\d{2})-(\d{2})\b/))) return validDate(+m[1], +m[2], +m[3]);
  if ((m = value.match(/\b(\d{1,2})\/(\d{1,2})\/(\d{4}|\d{2})\b/))) return validDate(twoDigitYear(+m[3]), +m[1], +m[2]);
  if ((m = value.match(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(20\d{2})\b/i))) {
    return validDate(+m[3], monthOf(m[1]), +m[2]);
  }
  return null;
}

function monthYearIn(value: string): MonthRef | null {
  const v = value.trim();
  let m: RegExpMatchArray | null;
  if ((m = v.match(/^(\d{1,2})\s*[/.-]\s*(\d{4}|\d{2,3})$/)) && +m[1] >= 1 && +m[1] <= 12) {
    const y = m[2].length === 4 ? +m[2] : m[2].length === 2 ? 2000 + +m[2] : null;
    return { month: +m[1], year: y };
  }
  if ((m = v.match(/^(\d{1,2})\/\d{1,2}\/(\d{2}|\d{4})$/)) && +m[1] <= 12) {
    return { month: +m[1], year: twoDigitYear(+m[2]) };
  }
  if ((m = v.match(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s*(20\d{2}|'?\d{2})?\b/i))) {
    return { month: monthOf(m[1]), year: m[2] ? twoDigitYear(+m[2].replace("'", "")) : null };
  }
  return null;
}

function field(fields: Record<string, string>, name: RegExp): string | null {
  for (const [k, v] of Object.entries(fields)) if (name.test(k) && v.trim()) return v;
  return null;
}

export type DocumentDate = { at: string; datedFrom: DatedFrom; period: MonthRef | null };

/**
 * The date a document's note carries.
 *
 * A monthly report is dated by the month it covers - the last day of it. Its
 * month comes from the name, then the form's Month/Year field, then the dates
 * of the visits it records. Anything else takes a date from the name, then
 * from the form or the text. Only when there is none anywhere does it take the
 * file's saved date, and it says so.
 */
export function documentDate(
  reading: NameReading,
  doc: { text: string; fields: Record<string, string>; fileModified: string | null; today: string },
): DocumentDate {
  const notFuture = (d: string | null) => (d && d <= doc.today ? d : null);
  const fileDate = (doc.fileModified ?? `${doc.today}T12:00:00Z`).slice(0, 10);

  const firstDocDate = (): string | null => {
    const fromField = field(doc.fields, /^date$|^date_2$|observation 1 date|completion date|date of crp signature/i);
    const d = fromField ? dateIn(fromField) : null;
    if (notFuture(d)) return d;
    const dated = doc.text.split("\n").find((l) => /date/i.test(l) && dateIn(l));
    const t = dateIn(dated ?? "") ?? dateIn(doc.text);
    return notFuture(t);
  };

  if (reading.periodic) {
    let period: MonthRef | null = reading.month;
    if (!period) {
      const v = field(doc.fields, /^month\s*\/?\s*year$/i);
      period = v ? monthYearIn(v) : null;
    }
    if (!period) {
      const m = doc.text.match(/month\s*\/\s*year:?\s*([^\n]{2,20})/i);
      period = m ? monthYearIn(m[1]) : null;
    }
    const inDoc = firstDocDate();
    if (!period && inDoc) period = { month: +inDoc.slice(5, 7), year: +inDoc.slice(0, 4) };

    if (period) {
      const year =
        period.year ??
        (inDoc && +inDoc.slice(5, 7) === period.month ? +inDoc.slice(0, 4) : inferYear(period.month, doc.fileModified, doc.today));
      const at = iso(year, period.month, lastDay(year, period.month));
      // A month still running is dated today, not the end of a month to come.
      return { at: at > doc.today ? doc.today : at, datedFrom: "Period covered", period: { month: period.month, year } };
    }
    return { at: fileDate, datedFrom: "File date (fallback)", period: null };
  }

  if (notFuture(reading.exactDate)) return { at: reading.exactDate!, datedFrom: "Named in the file", period: null };
  if (reading.sentMonthDay) {
    const { month, day } = reading.sentMonthDay;
    const d = validDate(inferYear(month, doc.fileModified, doc.today), month, day);
    if (notFuture(d)) return { at: d!, datedFrom: "Named in the file", period: null };
  }
  if (reading.month) {
    const year = reading.month.year ?? inferYear(reading.month.month, doc.fileModified, doc.today);
    const at = iso(year, reading.month.month, lastDay(year, reading.month.month));
    return { at: at > doc.today ? doc.today : at, datedFrom: "Named in the file", period: null };
  }
  const inDoc = firstDocDate();
  if (inDoc) return { at: inDoc, datedFrom: "Read from the document", period: null };
  return { at: fileDate, datedFrom: "File date (fallback)", period: null };
}

// ── which authorization ──────────────────────────────────────

export type AuthChoice =
  | { kind: "linked"; auth: AuthLite; how: string }
  | { kind: "new"; number: string; how: string }
  | { kind: "pick"; choices: AuthLite[]; why: string };

function covers(a: AuthLite, date: string): boolean {
  return Boolean(a.start_date && a.end_date && a.start_date <= date && date <= a.end_date);
}

function coversMonth(a: AuthLite, m: { month: number; year: number }): boolean {
  if (!a.start_date || !a.end_date) return false;
  const first = iso(m.year, m.month, 1);
  const last = iso(m.year, m.month, lastDay(m.year, m.month));
  return a.start_date <= last && first <= a.end_date;
}

/**
 * The authorization a document belongs on, in the order the owner set:
 *
 *   1. The V-number in the name. Several issues of one number (V0000375A, B,
 *      C) are told apart by the month the document names falling inside one's
 *      dates.
 *   2. Otherwise, the one authorization on file for the service the name gives.
 *   3. Otherwise, a V-number in the PDF's text.
 *   4. Otherwise, the document's date inside exactly one authorization's dates.
 *
 * Anything still open is a pick for a person, with the reason.
 */
export function chooseAuthorization(
  reading: NameReading,
  doc: {
    text: string;
    auths: AuthLite[];
    numbersElsewhere: string[];
    date: string | null;
    month: { month: number; year: number } | null;
  },
): AuthChoice {
  const byFamily = (list: AuthLite[]) =>
    reading.families.length === 0 ? list : list.filter((a) => reading.families.includes(familyOf(a.service_type) as Family));

  const byWindow = (list: AuthLite[]): AuthLite[] =>
    doc.month ? list.filter((a) => coversMonth(a, doc.month!)) : doc.date ? list.filter((a) => covers(a, doc.date!)) : [];

  const v = reading.vNumbers[0];
  if (v) {
    const issues = doc.auths.filter((a) => vKey(a.number) === vKey(v));
    if (issues.length === 0) {
      if (doc.numbersElsewhere.includes(vKey(v))) {
        return { kind: "pick", choices: byFamily(doc.auths), why: `${v} is on file for a different client` };
      }
      return { kind: "new", number: v, how: `${v} is not on file` };
    }

    let candidates = issues;
    if (issues.length > 1) {
      const inWindow = byWindow(issues);
      if (inWindow.length !== 1) {
        return {
          kind: "pick",
          choices: issues,
          why: `${issues.length} issues of ${v} are on file and ${inWindow.length === 0 ? "none has dates covering this document" : "more than one covers its date"}`,
        };
      }
      candidates = inWindow;
    }

    const auth = candidates[0];
    if (reading.families.length && !reading.families.includes(familyOf(auth.service_type) as Family)) {
      return {
        kind: "pick",
        choices: [auth],
        why: `the name says ${reading.families.join(" / ")}, and ${auth.number} on file is ${auth.service_type}`,
      };
    }
    return { kind: "linked", auth, how: issues.length > 1 ? `${v}, the issue covering its month` : `${v} in the name` };
  }

  if (reading.families.length > 1) {
    return { kind: "pick", choices: byFamily(doc.auths), why: `the name gives ${reading.families.length} services` };
  }

  const ofService = byFamily(doc.auths);
  if (reading.families.length === 1 && ofService.length === 1) {
    return { kind: "linked", auth: ofService[0], how: `the only ${reading.families[0]} authorization on file` };
  }

  const pool = ofService.length ? ofService : doc.auths;

  const tokens = doc.text.toUpperCase().match(/[A-Z0-9]+/g) ?? [];
  const inText = new Set(tokens.map(vKey).filter((k) => k.length >= 6));
  const named = pool.filter((a) => vKey(a.number).length >= 6 && inText.has(vKey(a.number)));
  if (named.length === 1) {
    return { kind: "linked", auth: named[0], how: `${named[0].number} in the document` };
  }

  const dated = byWindow(pool);
  if (dated.length === 1) {
    return { kind: "linked", auth: dated[0], how: "the only one whose dates cover the document" };
  }

  // The reason names what was actually on file: "no Job Placement authorization"
  // is a different problem from "two of them", and a person needs to know which.
  const plural = (n: number, what: string) => `${n} ${what} authorization${n === 1 ? "" : "s"}`;
  return {
    kind: "pick",
    choices: pool,
    why:
      pool.length === 0
        ? "no authorization on file for this client"
        : reading.families.length === 1 && ofService.length === 0
          ? `no ${reading.families[0]} authorization on file (${plural(pool.length, "other")})`
          : reading.families.length === 1
            ? `${plural(pool.length, reading.families[0])} on file and nothing says which`
            : `${plural(pool.length, "")} on file and nothing in the name says which`.replace("  ", " "),
  };
}

/** The service a new authorization is proposed with, where the name and text settle it. */
export function proposedService(reading: NameReading, text: string, fields: Record<string, string>): string | null {
  if (reading.families.length !== 1) return null;
  const f = reading.families[0];
  if (f === "Job Development") {
    if (!reading.hqIndicator) return "Job Development";
    return reading.jobDevelopmentNamed ? "Job Development + HQ Indicator" : "HQ Indicator";
  }
  if (f === "Job Placement") return reading.supported ? "Job Placement (SE)" : "Job Placement";
  if (f === "WSA") {
    const tier = `${text}\n${Object.values(fields).join("\n")}`.match(/\btier\s*(1|2|I{1,2})\b/i);
    return tier ? `WSA Tier ${tier[1].length === 2 || tier[1] === "2" ? 2 : 1}` : null;
  }
  return f;
}

// ── the note's words ─────────────────────────────────────────

/** A filled form as "Field: value" lines, in the form's own order. */
export function formFieldsText(fields: Record<string, string>): string {
  return Object.entries(fields)
    .filter(([, v]) => v.trim() && v !== "Off")
    .map(([k, v]) => `${k.replace(/_\d+$/, "").trim()}: ${v}`)
    .join("\n");
}

export function noteText(
  reading: NameReading,
  filename: string,
  date: DocumentDate,
  content: { text: string; fields: Record<string, string> },
): string {
  const heading = `${reading.label || "Document"} — ${filename}`;
  const when =
    date.datedFrom === "Period covered" && date.period
      ? `Covers ${MONTH_NAMES[date.period.month - 1]} ${date.period.year}.`
      : date.datedFrom === "File date (fallback)"
        ? `Dated ${date.at} from the file's saved date: neither the name nor the document gives one.`
        : date.datedFrom === "Named in the file"
          ? `Dated ${date.at}, from the file name.`
          : `Dated ${date.at}, from the document.`;

  const filled = formFieldsText(content.fields);
  const text = content.text.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  const body = filled
    ? filled
    : text.replace(/\s/g, "").length >= 40
      ? text.length > 20000
        ? `${text.slice(0, 20000)}\n… (the rest is in the attached file)`
        : text
      : "A scan: nothing in it could be read as text. Open the attached file.";

  return `${heading}\n${when}\n\n${body}`;
}

// ── the plan ─────────────────────────────────────────────────

export type PlanInput = {
  filename: string;
  clientName: string;
  fileModified: string | null;
  today: string;
  /** What the PDF's text was classified as. */
  textKind: string;
  /** "93", from the text, when the text names one USOR form. */
  textUsor: string | null;
  text: string;
  fields: Record<string, string>;
  parsedAuth: { start: string | null; end: string | null } | null;
  auths: AuthLite[];
  /** vKey of every authorization number on file for other clients. */
  numbersElsewhere: string[];
};

export type Plan =
  | {
      action: "note";
      reading: NameReading;
      noteType: NoteType;
      at: string;
      datedFrom: DatedFrom;
      text: string;
      category: Category;
      restricted: boolean;
      outcome: string;
    }
  | {
      action: "link";
      reading: NameReading;
      authId: string;
      authNumber: string;
      category: "Authorization" | "Invoice";
      start: string | null;
      end: string | null;
      outcome: string;
    }
  | { action: "attach"; reading: NameReading; category: Category; outcome: string }
  | { action: "ignore"; reading: NameReading; reason: string }
  | {
      action: "propose";
      reading: NameReading;
      named: "Authorization" | "Invoice";
      number: string | null;
      serviceType: string | null;
      choices: AuthLite[];
      why: string;
    }
  | { action: "leave"; reading: NameReading; why: string };

export function planDocument(input: PlanInput): Plan {
  let reading = readFilename(input.filename, input.clientName);
  const content = { text: input.text, fields: input.fields };

  // A warrant is a payment, and has its own careful path.
  if (input.textKind === "Warrant") {
    return { action: "leave", reading, why: "the document is a warrant" };
  }

  // A name that says nothing about what the document is: its text decides.
  if (["Nothing in the name", "Service only", "Unmatched"].includes(reading.pattern)) {
    const u = input.textKind === "USOR form" && input.textUsor ? usorFiling(input.textUsor) : null;
    if (u && input.textUsor !== "148") {
      reading = {
        ...reading,
        pattern: "Report",
        usor: input.textUsor,
        category: "Signed USOR form",
        noteType: u.noteType,
        label: u.label,
        periodic: u.periodic,
        restricted: u.restricted,
      };
    } else if (input.textKind === "Authorization") {
      reading = { ...reading, pattern: "Authorization", category: "Authorization", label: "Authorization" };
    } else {
      return { action: "leave", reading, why: "neither the name nor the document says what it is" };
    }
  }

  // The text outranks the name. A PDF named as an authorization whose own text
  // is readable and carries none of an authorization's marks has, every time,
  // been the invoice for it: a date, a service and an amount. The owner's
  // ruling on the first nine, 2026-09-14: "the text is the invoice, whatever
  // the filename says". A scan has no text to outrank anything.
  if (
    reading.pattern === "Authorization" &&
    input.textKind === "Other" &&
    input.text.replace(/\s/g, "").length >= 40
  ) {
    reading = { ...reading, pattern: "Invoice", category: "Invoice", label: "Invoice" };
  }

  switch (reading.pattern) {
    case "Not a client document":
      return { action: "ignore", reading, reason: "Business filing paperwork, not a client document" };

    case "Billable hours form":
    case "Attach":
      return { action: "attach", reading, category: reading.category ?? "Other", outcome: `Filed as ${reading.category ?? "Other"} (${reading.label})` };

    case "Report":
    case "Resume": {
      const date = documentDate(reading, { ...content, fileModified: input.fileModified, today: input.today });
      return {
        action: "note",
        reading,
        noteType: reading.noteType ?? "General",
        at: date.at,
        datedFrom: date.datedFrom,
        text: noteText(reading, input.filename, date, content),
        category: reading.category ?? "Other",
        restricted: reading.restricted,
        outcome: `Filed as a note: ${reading.label} (${reading.noteType ?? "General"})`,
      };
    }

    case "Authorization":
    case "Invoice": {
      const named = reading.pattern;
      const date = documentDate({ ...reading, periodic: Boolean(reading.month) }, { ...content, fileModified: input.fileModified, today: input.today });
      const choice = chooseAuthorization(reading, {
        text: `${input.text}\n${Object.values(input.fields).join("\n")}`,
        auths: input.auths,
        numbersElsewhere: input.numbersElsewhere,
        date: date.datedFrom === "File date (fallback)" ? null : date.at,
        month: date.period && date.period.year ? { month: date.period.month, year: date.period.year } : null,
      });

      if (choice.kind === "linked") {
        return {
          action: "link",
          reading,
          authId: choice.auth.id,
          authNumber: choice.auth.number,
          category: named,
          start: named === "Authorization" ? (input.parsedAuth?.start ?? null) : null,
          end: named === "Authorization" ? (input.parsedAuth?.end ?? null) : null,
          outcome:
            named === "Invoice"
              ? `Billed against ${choice.auth.number} (${choice.how})`
              : `Linked to authorization ${choice.auth.number} (${choice.how})`,
        };
      }
      if (choice.kind === "new") {
        return {
          action: "propose",
          reading,
          named,
          number: named === "Authorization" ? choice.number : null,
          serviceType: proposedService(reading, input.text, input.fields),
          choices: named === "Invoice" ? input.auths : [],
          why:
            named === "Authorization"
              ? `${choice.how}: confirm it to create the authorization`
              : `${choice.how}, so there is no authorization to bill it against yet`,
        };
      }
      return {
        action: "propose",
        reading,
        named,
        number: null,
        serviceType: proposedService(reading, input.text, input.fields),
        choices: choice.choices,
        why: choice.why,
      };
    }
  }

  return { action: "leave", reading, why: "nothing to do" };
}
