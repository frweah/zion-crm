/**
 * The CRP billing pathway, as USOR publishes it.
 *
 * From two documents the owner supplied (20 Sept 2026): "Billing Pathway for
 * CRPs providing SJBT/SE" and the CRP billing process sheet. Everything here
 * is transcribed from them - nothing is inferred, and where the documents are
 * silent this file is silent too.
 *
 * It is reference, not enforcement. The CRM's rules stay where they are: the
 * rate on the authorization decides what may be invoiced (the amount guard in
 * 0002), the forms gate decides what may be sent, and a person decides when.
 * What this adds is the stage a piece of work belongs to and the three things
 * the pathway is explicit about and the CRM was not -
 *
 *   which date belongs on the invoice, which is almost never today;
 *   what has to be true before it may be billed at all;
 *   when the paperwork is due.
 *
 * The fees are the published schedule, shown so somebody can see at a glance
 * whether what they are about to claim is the usual figure. They are never
 * written onto an invoice: the authorization's own rate is what USOR agreed
 * to for this client, and where the two disagree the authorization wins.
 */
export type CrpStage = {
  key: string;
  label: string;
  /** The service types on an authorization that put it in this stage. */
  services: string[];
  /** The form template ids this stage bills on. */
  forms: string[];
  /** What date goes in the invoice's date box. */
  invoiceDate: string;
  /** What must be true before it may be billed. */
  billsWhen: string;
  /** When the paperwork is due, where the pathway says. */
  dueBy: string | null;
  /** The published figures, for comparison only. */
  fees: { label: string; amount: number }[];
};

export const CRP_STAGES: CrpStage[] = [
  {
    key: "wsa",
    label: "Work Strategy Assessment",
    services: ["WSA Tier 1", "WSA Tier 2"],
    forms: ["wsa"],
    invoiceDate: "the first day of WSA activities",
    billsWhen:
      "the WSA activities are done and the team meeting with the client and the VR counselor has happened",
    dueBy: null,
    fees: [
      { label: "Tier One", amount: 270 },
      { label: "Tier Two", amount: 585 },
    ],
  },
  {
    key: "development",
    label: "Job Development",
    services: ["Job Development", "Job Development + HQ Indicator"],
    forms: ["usor96"],
    invoiceDate: "the first meeting with the client to look for work",
    billsWhen: "the first month of development activities is complete",
    dueBy: "the 15th of the following month",
    fees: [
      { label: "Job Development", amount: 560 },
      { label: "Rural", amount: 1120 },
    ],
  },
  {
    key: "placement",
    label: "Job Placement",
    services: ["Job Placement", "Job Placement (SE)"],
    forms: ["usor60", "usor92"],
    invoiceDate: "the client's first day of work",
    billsWhen: "the client has kept the job for five shifts — a split shift counts as one",
    dueBy: null,
    fees: [
      { label: "SJBT", amount: 2250 },
      { label: "Supported Employment", amount: 3375 },
    ],
  },
  {
    key: "coaching",
    label: "Job Coaching",
    services: ["Job Coaching"],
    forms: ["usor93", "usor95"],
    invoiceDate: "the first coaching day of the month",
    billsWhen: "the month is over — it is billed monthly, starting the first day on the job",
    dueBy: "the 15th of the following month",
    fees: [{ label: "Per hour", amount: 45 }],
  },
  {
    key: "lifeskills",
    label: "Life Skills and Job Readiness",
    services: ["Life Skills", "Job Readiness", "CRP Group Training", "Supported Employment"],
    forms: ["usor148"],
    invoiceDate: "the first day of the month being reported",
    billsWhen: "the month is over — it is completed and emailed monthly",
    dueBy: "30 days",
    fees: [],
  },
];

/**
 * High Quality Indicators.
 *
 * Billed against their own authorization, raised by the counselor once the
 * client is stable: 30 days of employment meeting the SJBT criteria, or for
 * Supported Employment 80/20 or 24 months with extended services in place.
 * Each indicator that is true is worth the same again.
 */
export const HQI_AMOUNT = 560;

export const HQI_INDICATORS = [
  { key: "hours", label: "Hours", test: "SJBT 30 hours a week or more; SE 20 hours a week or more" },
  { key: "wages", label: "Wages", test: "SJBT $14/hr or more; SE $10/hr or more" },
  { key: "benefits", label: "Benefits", test: "the employer pays health benefits" },
  {
    key: "days",
    label: "Days to placement",
    test: "60 days or less from the job development authorization to the employment start date",
  },
  { key: "stem", label: "STEM", test: "the occupation is listed as STEM on O*NET" },
  { key: "rural", label: "Rural", test: "the client lives in a rural area" },
];

/** Where every claim and every form goes, whatever the office. */
export const CRP_BILLING_NOTE =
  "USOR asks for the form and the bill together, emailed to the billing office.";

export function stageForService(service: string): CrpStage | null {
  return CRP_STAGES.find((s) => s.services.includes(service)) ?? null;
}

export function stageForTemplate(templateId: string): CrpStage | null {
  return CRP_STAGES.find((s) => s.forms.includes(templateId)) ?? null;
}

/**
 * When a month's paperwork is due, for the stages that say.
 *
 * "The 15th of the following month" is the only dated rule in the pathway, and
 * it is the one worth counting: a month's coaching billed on the 20th is a
 * month's coaching billed late.
 */
export function dueDateFor(stage: CrpStage | null, month: string): string | null {
  if (!stage || stage.dueBy !== "the 15th of the following month") return null;
  if (!/^\d{4}-\d{2}$/.test(month)) return null;
  const [y, m] = month.split("-").map(Number);
  const next = m === 12 ? { y: y + 1, m: 1 } : { y, m: m + 1 };
  return `${next.y}-${String(next.m).padStart(2, "0")}-15`;
}
