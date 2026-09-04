/**
 * The eight DWS-USOR form templates, faithful to the forms on file.
 *
 * Field types:
 *   text, textarea, date, number, month, select, check, checks (multi),
 *   rating (1–10), yesno (with optional explanation), table (rows × columns).
 *
 * Autofill is not here — it needs the database, so it lives in
 * lib/form-autofill.ts and runs on the server.
 */

export type FieldType =
  | "text"
  | "textarea"
  | "date"
  | "number"
  | "month"
  | "select"
  | "check"
  | "checks"
  | "rating"
  | "yesno"
  | "table";

export type TableColumn = [key: string, label: string, type: "date" | "number" | "text" | "code"];

export type Field =
  | { heading: string }
  | {
      k: string;
      l: string;
      t: FieldType;
      o?: string[];
      explain?: boolean;
      cols?: TableColumn[];
    };

export type FormTemplate = {
  id: string;
  usor: string;
  name: string;
  services: string[];
  requiredForBilling: boolean;
  monthly?: boolean;
  incoming?: boolean;
  sensitive?: boolean;
  due: string;
  fields: Field[];
};

export function isHeading(f: Field): f is { heading: string } {
  return "heading" in f;
}

const WORKSITE_ROWS: [string, string][] = [
  ["attendance", "Attendance: arrives and leaves on time, maintains proper attendance"],
  ["time", "Time Management: takes meals and breaks appropriately"],
  ["appearance", "Appearance: grooming and hygiene appropriate for the workplace"],
  ["communication", "Communication: uses appropriate communication skills"],
  ["completion", "Job Task Completion Rate: performance comparable to coworkers"],
  ["quality", "Job Task Quality: work product meets the employer's standards"],
];

const NATURAL_ROWS: [string, string][] = [
  ["enjoy", "Does the client enjoy the job?"],
  ["ready", "Does the client have difficulty getting ready for the job?"],
  ["motivated", "Is the client motivated to earn money in the job?"],
  ["neat", "Is the client careful to maintain neat appearance when reporting to work?"],
  ["behave", "Does the client behave appropriately when outside the home?"],
  ["complain", "Does the client complain about the job?"],
  ["transport", "Is transportation to and from work a problem for the client?"],
  ["positive", "Does the client speak positively about the job with supervisors and co-workers?"],
];

const ratings = (prefix: string, rows: [string, string][]): Field[] =>
  rows.map(([k, l]) => ({ k: prefix + k, l, t: "rating" as const }));

const RESOURCE_FIELDS: Field[] = [
  { heading: "Resources available to client" },
  {
    k: "extended",
    l: "Extended services provider (Supported Employment)",
    t: "checks",
    o: ["DSPD", "Mental Health Provider", "Partnership Plus (TTW)", "Other"],
  },
  { k: "extendedDetail", l: "Provider detail", t: "text" },
  {
    k: "insurance",
    l: "Health insurance",
    t: "checks",
    o: ["Medicaid", "Medicare", "Parent's Insurance", "Spouse's Insurance", "Other"],
  },
  { k: "ss", l: "Social Security benefits", t: "checks", o: ["SSI", "SSDI"] },
  {
    k: "benefitsPlanning",
    l: "Benefits planning",
    t: "select",
    o: ["Completed", "Pending", "Not Applicable"],
  },
  { k: "benefitsDate", l: "Pending — date scheduled", t: "date" },
  { k: "benefitsSummary", l: "Benefits summary info", t: "textarea" },
  { k: "otherServices", l: "Other services/benefits", t: "textarea" },
];

const CLIENT_PROFILE_FIELDS: Field[] = [
  { k: "skills", l: "Current work skills (knowledge, skills, abilities)", t: "textarea" },
  { k: "needs", l: "Work skill development needs", t: "textarea" },
  { k: "jobs", l: "Jobs of interest", t: "textarea" },
  { k: "interpersonal", l: "Interpersonal/social skills", t: "textarea" },
  { k: "at", l: "Identified assistive technology needs", t: "textarea" },
  { k: "commNeeds", l: "Communication needs (interpreter, etc.)", t: "textarea" },
  { k: "behavioral", l: "Behavioral/self-regulation", t: "textarea" },
  { k: "adls", l: "Activities of daily living (hygiene, meal prep, etc.)", t: "textarea" },
  { k: "family", l: "Family issues/supports", t: "textarea" },
  { k: "criminal", l: "Criminal background (expungement, etc.)", t: "textarea" },
  { k: "school", l: "School/academic", t: "textarea" },
];

export const FORM_TEMPLATES: FormTemplate[] = [
  {
    id: "usor60",
    usor: "DWS-USOR 60",
    name: "CRP Evaluation of Competitive Integrated Employment (CIE) — Job Placement Report",
    services: ["Job Placement", "Job Placement (SE)"],
    requiredForBilling: true,
    due: "Submit to VR with billing for job placement.",
    fields: [
      { k: "employer", l: "Employer", t: "text" },
      { k: "employerAddress", l: "Employer address", t: "text" },
      { k: "title", l: "Job title", t: "text" },
      { k: "start", l: "Employment start date", t: "date" },
      { k: "wage", l: "Wage", t: "text" },
      { k: "hours", l: "Hours/week", t: "number" },
      { k: "benefits", l: "Benefits", t: "text" },
      { k: "supervisor", l: "Supervisor name", t: "text" },
      { k: "supervisorContact", l: "Supervisor contact", t: "text" },
      { heading: "CIE Part 1: Integrated Work Setting — all must be Yes" },
      { k: "q1", l: "1. Is employment setting typically found in the community?", t: "yesno" },
      {
        k: "q2",
        l: "2. Is the client's position integrated in the work setting (NOT an enclave)?",
        t: "yesno",
      },
      {
        k: "q3",
        l: "3. Does the client interact with other persons who are not individuals with disabilities to the same extent as comparable employees?",
        t: "yesno",
        explain: true,
      },
      {
        k: "q4",
        l: "4. Is the prevalence of coworkers with disabilities similar to that found in the community?",
        t: "yesno",
        explain: true,
      },
      { k: "q5", l: "5. Is the employer a non-CRP business/work setting?", t: "yesno" },
      { heading: "CIE Part 2: Competitive Wages — all must be Yes" },
      { k: "q6", l: "6. Is the client compensated at or above minimum wage?", t: "yesno" },
      {
        k: "q7",
        l: "7. Wages greater than or equal to the customary rate paid for the same or similar work by employees without disabilities?",
        t: "yesno",
        explain: true,
      },
      {
        k: "q8",
        l: "8. Same opportunities for advancement as employees without disabilities in similar positions?",
        t: "yesno",
        explain: true,
      },
      {
        k: "q9",
        l: "9. Access to the same benefits as employees without disabilities in similar positions?",
        t: "yesno",
        explain: true,
      },
      {
        k: "q10",
        l: "10. Does this placement meet ALL criteria above (all boxes in parts 1 and 2 Yes)? If No, it cannot be billed as a placement — consult the VR Counselor.",
        t: "yesno",
      },
      { heading: "High Quality Indicators" },
      {
        k: "hq",
        l: "Indicators met",
        t: "checks",
        o: [
          "Hours (SJBT 30+ hrs/wk, SE 20+ hrs/wk)",
          "Wages (SJBT $14/hr+, SE $10/hr+)",
          "Benefits (employer-paid health benefits available)",
          "Days to Placement (60 days or less from JD authorization to start)",
          "STEM (O-NET STEM occupation)",
          "Rural (client lives in a rural county)",
        ],
      },
    ],
  },

  {
    id: "usor92",
    usor: "DWS-USOR 92",
    name: "Initial Job Placement Assessment",
    services: ["Job Placement", "Job Placement (SE)"],
    requiredForBilling: true,
    due: "Complete after the client's 5th work day. Submit with the job placement milestone bill along with the employer verification form.",
    fields: [
      { k: "date", l: "Date", t: "date" },
      { k: "employer", l: "Employer", t: "text" },
      { k: "supervisor", l: "Supervisor", t: "text" },
      { heading: "Worksite Evaluation (1 = Never, 10 = Always)" },
      ...ratings("w_", WORKSITE_ROWS),
      { k: "appraisal", l: "Overall appraisal of the employee/client's performance", t: "textarea" },
      { k: "problems", l: "Problems experienced by the employee/client", t: "textarea" },
      { heading: "Natural Support Evaluation (1 = Never, 10 = Always)" },
      ...ratings("n_", NATURAL_ROWS),
      {
        k: "worried",
        l: "Is the client worried that he or she will lose the job for some reason?",
        t: "textarea",
      },
      {
        k: "family",
        l: "Does the client's family have any concerns about the new job?",
        t: "textarea",
      },
    ],
  },

  {
    id: "usor93",
    usor: "DWS-USOR 93",
    name: "Ongoing Supports — Monthly Job Coaching Report",
    services: ["Job Coaching"],
    requiredForBilling: true,
    monthly: true,
    due: "Complete twice per month during worksite visits. Submit with the month's hour tracking log (USOR 95) and billing statement, by the 15th of the following month.",
    fields: [
      { k: "month", l: "Month/Year", t: "month" },
      { k: "date", l: "Report date", t: "date" },
      { k: "employer", l: "Employer", t: "text" },
      { k: "supervisor", l: "Supervisor", t: "text" },
      { k: "obs1", l: "Worksite Observation 1 date", t: "date" },
      { heading: "Worksite Observation 1 (1 = Never, 10 = Always)" },
      ...ratings("o1_", WORKSITE_ROWS),
      { k: "obs2", l: "Worksite Observation 2 date", t: "date" },
      { heading: "Worksite Observation 2 (1 = Never, 10 = Always)" },
      ...ratings("o2_", WORKSITE_ROWS),
      { k: "appraisal", l: "Overall appraisal of the employee/client's performance", t: "textarea" },
      { k: "problems", l: "Problems experienced by the employee/client", t: "textarea" },
      { k: "interventionsUsed", l: "Interventions used", t: "textarea" },
      { k: "interventionsRecommended", l: "Recommended interventions", t: "textarea" },
      { k: "contact", l: "Request counselor contact?", t: "check" },
    ],
  },

  {
    id: "wsa",
    usor: "DWS-USOR 94",
    name: "Work Strategy Assessment",
    services: ["WSA Tier 1", "WSA Tier 2"],
    requiredForBilling: true,
    sensitive: true,
    due: "Completed by the VR Counselor, the CRP, and the client. Due when the team meets to review results, agree to goals, and sign.",
    fields: [
      {
        k: "tier",
        l: "Tier billed",
        t: "select",
        o: ["Tier 1", "Tier 2 (incl. situational assessment)"],
      },
      { heading: "Counselor Referral Page (from the counselor)" },
      { k: "address", l: "Address", t: "text" },
      { k: "city", l: "City", t: "text" },
      { k: "state", l: "State", t: "text" },
      { k: "zip", l: "ZIP", t: "text" },
      { k: "phone", l: "Client phone", t: "text" },
      { k: "cell", l: "Client cell", t: "text" },
      { k: "guardianship", l: "Guardianship", t: "yesno" },
      { k: "guardian", l: "If yes, parent/guardian name and phone", t: "text" },
      { k: "referralQuestion", l: "Referral question", t: "textarea" },
      ...RESOURCE_FIELDS,
      { heading: "As it applies to the client" },
      ...CLIENT_PROFILE_FIELDS,
      { heading: "CRP Observation and Report — Work Assessment (4 hours)" },
      {
        k: "workAreas",
        l: "Areas assessed",
        t: "checks",
        o: [
          "Soft skills",
          "Job experiences (work sample)",
          "Transferable skills",
          "Interpersonal skills",
          "Client interest (job goal)",
          "Self-direction",
          "Physical abilities",
          "How the client reacts to criticism",
        ],
      },
      {
        k: "workSite",
        l: "Worksite simulation location (must simulate a CIE industry of interest)",
        t: "text",
      },
      { k: "workObs", l: "Observations", t: "textarea" },
      { heading: "Natural Support Assessment (1 hour)" },
      {
        k: "nsAreas",
        l: "Areas monitored",
        t: "checks",
        o: [
          "Family support",
          "Other natural supports",
          "Parent/guardian expectations",
          "How the client reacts to working with others",
          "Safety concerns",
          "Professional boundaries",
        ],
      },
      { k: "nsObs", l: "Observations", t: "textarea" },
      { heading: "Life Skills (1 hour)" },
      {
        k: "lsAreas",
        l: "Areas addressed",
        t: "checks",
        o: [
          "Presentation: personal appearance and hygiene",
          "Self-care including meal prep/grocery shopping",
          "Financial literacy",
        ],
      },
      { k: "lsObs", l: "Observations", t: "textarea" },
      { heading: "Transportation Assessment (30 min)" },
      {
        k: "trAreas",
        l: "Areas assessed",
        t: "checks",
        o: [
          "Businesses or industries available close to the client",
          "Proximity of employment opportunities to home",
        ],
      },
      { k: "trPublic", l: "Transportation options — public", t: "text" },
      { k: "trPrivate", l: "Transportation options — private", t: "text" },
      { k: "trObs", l: "Observations", t: "textarea" },
      { heading: "Computer Skill Assessment (30 min)" },
      {
        k: "csAreas",
        l: "Areas assessed",
        t: "checks",
        o: ["Ability to complete online application", "Social media (social skills and protocol)"],
      },
      { k: "csOther", l: "Other skills (typing test, 10 key, etc.)", t: "text" },
      { k: "csObs", l: "Observations", t: "textarea" },
      { heading: "Interview Skill Assessment (1 hour)" },
      {
        k: "ivAreas",
        l: "Areas monitored",
        t: "checks",
        o: [
          "Mock interview",
          "Communication skills",
          "Body language/posture",
          "Interview-appropriate dress",
          "Listening skills",
          "Ability to answer directed questions",
        ],
      },
      { k: "ivObs", l: "Observations", t: "textarea" },
      { k: "otherObs", l: "Other observations", t: "textarea" },
      { heading: "Recommendations — CRP recommended strategy for achieving CIE" },
      { k: "strategy", l: "Recommended strategy", t: "textarea" },
      { k: "jsHours", l: "Planned job search hours/week", t: "number" },
      { k: "lifeSkillsNeeded", l: "Life skills needed", t: "textarea" },
      { k: "lifeSkillsHours", l: "Life skills hours requested", t: "number" },
      { k: "targetOcc", l: "Recommended target occupations", t: "textarea" },
      { k: "jobSupports", l: "Recommended supports on the job", t: "textarea" },
      { heading: "Team Section — CRP, VR Counselor, DSPD, and client" },
      { k: "specialist", l: "Assigned employment specialist / job coach", t: "text" },
      { k: "acre", l: "ACRE certified?", t: "yesno" },
      {
        k: "jointJD",
        l: "Joint VR/CRP recommendations for job development supports",
        t: "textarea",
      },
      { k: "jointOngoing", l: "Joint VR/CRP recommendations for ongoing supports", t: "textarea" },
      { k: "jobGoal", l: "Job goal (must align with IPE goal)", t: "text" },
      { k: "payRange", l: "Industry targeted pay range", t: "text" },
      { k: "benefitsOther", l: "Benefits/other", t: "text" },
      {
        k: "hoursAvail",
        l: "Hours available to work",
        t: "checks",
        o: [
          "Full Time",
          "Part Time",
          "< 10 hours/wk",
          "Days",
          "Graveyard",
          "Swing shift",
          "Weekends",
          "Other",
        ],
      },
      { k: "hoursOther", l: "Other (specify)", t: "text" },
      { k: "clientSigned", l: "Client signature date", t: "date" },
      { k: "counselorSigned", l: "VR Counselor signature date", t: "date" },
    ],
  },

  {
    id: "usor95",
    usor: "DWS-USOR 95",
    name: "Job Coaching Tracker",
    services: ["Job Coaching"],
    requiredForBilling: true,
    monthly: true,
    due: "Attach the client's work schedule. Due by end of business on the 15th day of the following month.",
    fields: [
      { k: "month", l: "Month/Year", t: "month" },
      { k: "employer", l: "Employer", t: "text" },
      { k: "coachingHours", l: "Coaching hours (this month)", t: "number" },
      { k: "clientHours", l: "Total client hours worked", t: "number" },
      { k: "ratio", l: "Ratio percentage (coaching ÷ client hours)", t: "text" },
      { k: "authorized", l: "Originally authorized hours", t: "number" },
      { k: "used", l: "Hours used (to date)", t: "number" },
      { k: "remaining", l: "Hours remaining", t: "number" },
      {
        k: "rows",
        l: "Daily coaching log",
        t: "table",
        cols: [
          ["day", "Day", "date"],
          ["coach", "Job coach name", "text"],
          ["hours", "Hours", "number"],
          ["primary", "Primary service", "code"],
          ["secondary", "Secondary service", "code"],
        ],
      },
      { k: "schedule", l: "Client's work schedule attached", t: "check" },
    ],
  },

  {
    id: "usor96",
    usor: "DWS-USOR 96",
    name: "Job Development Monthly Report",
    services: ["Job Development", "Job Development + HQ Indicator"],
    requiredForBilling: true,
    monthly: true,
    due: "Due by end of business on the 15th day of the following month.",
    fields: [
      { k: "month", l: "Month/Year", t: "month" },
      { k: "goal", l: "Job goal", t: "text" },
      { k: "totalHours", l: "Total development hours", t: "number" },
      {
        k: "rows",
        l: "Job development activity",
        t: "table",
        cols: [
          ["day", "Day", "date"],
          ["hours", "Hours", "number"],
          ["activity", "JD Activity", "text"],
          ["outcome", "Outcome", "text"],
          ["next", "Next Steps (i.e. referral to USOR or other services)", "text"],
        ],
      },
      {
        k: "summary",
        l: "Summary: other pertinent information, including barriers to CIE",
        t: "textarea",
      },
      { k: "contact", l: "Requesting counselor contact", t: "check" },
      { k: "contactPhone", l: "Preferred contact #", t: "text" },
      { k: "contactEmail", l: "Email", t: "text" },
    ],
  },

  {
    id: "usor98",
    usor: "DWS-USOR 98",
    name: "Referral for CRP Assessment (received from VR Counselor)",
    services: [],
    requiredForBilling: false,
    incoming: true,
    sensitive: true,
    due: "Completed by the VR Counselor and sent with the Authorization for Services. Record it here so intake has the counselor's information.",
    fields: [
      {
        k: "referralType",
        l: "Referred for",
        t: "checks",
        o: ["Discovery Assessment", "Career Profile (IPS)", "Pathways-Discovery", "Other"],
      },
      { k: "referralOther", l: "Other (specify)", t: "text" },
      { k: "guardianship", l: "Guardianship", t: "yesno" },
      { k: "guardian", l: "Parent/guardian name and phone", t: "text" },
      ...RESOURCE_FIELDS,
      { heading: "As it applies to the client" },
      ...CLIENT_PROFILE_FIELDS,
      { heading: "CRP information" },
      { k: "specialist", l: "Assigned employment specialist / job coach", t: "text" },
      { k: "acre", l: "ACRE certified?", t: "yesno" },
      { k: "ce", l: "CE certification (if applicable)?", t: "yesno" },
      { k: "counselorSigned", l: "VR Counselor signature date on the form", t: "date" },
    ],
  },

  {
    id: "usor148",
    usor: "DWS-USOR 148",
    name: "CRP Billable Hours Form (Job Readiness, Financial Literacy, Supported Education, etc.)",
    services: ["Life Skills", "CRP Group Training", "Job Readiness", "Supported Employment"],
    requiredForBilling: true,
    due: "Due upon completion of the billable service hours for an approved service.",
    fields: [
      { k: "goal", l: "Job goal", t: "text" },
      { k: "totalHours", l: "Total billable hours", t: "number" },
      { k: "completion", l: "Completion date", t: "date" },
      {
        k: "rows",
        l: "Service log",
        t: "table",
        cols: [
          ["day", "Date", "date"],
          ["hours", "Hours", "number"],
          ["activity", "Activity", "text"],
          ["obs", "CRP observations and comments", "text"],
        ],
      },
      { k: "summary", l: "Summary: overall information or observations", t: "textarea" },
      { k: "contact", l: "Requesting counselor contact", t: "check" },
      { k: "contactPhone", l: "Preferred contact #", t: "text" },
      { k: "contactEmail", l: "Email", t: "text" },
    ],
  },
];

export function templateById(id: string): FormTemplate | undefined {
  return FORM_TEMPLATES.find((t) => t.id === id);
}

export function templatesForService(serviceType: string | null | undefined): FormTemplate[] {
  if (!serviceType) return [];
  return FORM_TEMPLATES.filter((t) => t.services.includes(serviceType));
}

/**
 * USOR 60 rule: if any CIE question is answered No, question 10 must also be
 * No — the placement cannot be billed as competitive integrated employment.
 */
export function validateForm(templateId: string, data: Record<string, unknown>): string {
  if (templateId !== "usor60") return "";
  const cie = ["q1", "q2", "q3", "q4", "q5", "q6", "q7", "q8", "q9"];
  const anyNo = cie.some((q) => (data[q] as { v?: string } | undefined)?.v === "No");
  const q10 = (data.q10 as { v?: string } | undefined)?.v;
  if (anyNo && q10 !== "No") {
    return "One or more CIE questions is No — question 10 must also be No, and the placement cannot be billed.";
  }
  return "";
}
