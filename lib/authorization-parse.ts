/**
 * Reading a USOR authorization.
 *
 * Deterministic on purpose, and the owner asked for it that way: rules that
 * either match or do not, no service, no model, nothing that reads a client's
 * authorization on somebody else's machine. The same file gives the same
 * answer every time, and when it is wrong it is wrong in a way somebody can
 * look at and fix — a rule, in this file, with a name.
 *
 * Nothing here creates an authorization. It produces a proposal, every field
 * carrying where it came from, and a person confirms it. A parser that wrote
 * straight to the record would put a wrong rate on a client's file at the
 * speed of an upload.
 *
 * A scan has no text to read. That case is detected rather than guessed at,
 * and named as the thing Azure Document Intelligence is for — which is not
 * built and is not pretended to be.
 */

export type FieldKey =
  | "authNumber"
  | "clientName"
  | "agencyId"
  | "serviceType"
  | "totalHours"
  | "rate"
  | "rateType"
  | "startDate"
  | "endDate"
  | "counselorName"
  | "office";

export type Found = {
  value: string;
  /** The line the value was taken from, so a person can check it by eye. */
  source: string;
  /** Which rule matched, so a wrong answer leads to the rule that gave it. */
  rule: string;
};

export type ParsedAuthorization = {
  fields: Partial<Record<FieldKey, Found>>;
  missing: FieldKey[];
  warnings: string[];
  scanned: boolean;
  pages: number;
  /** Every line read, for the "what did it actually see" panel. */
  lines: string[];
};

/**
 * A rule is a label and what may follow it.
 *
 * USOR forms put the label and the value on the same line more often than
 * not, so each rule tries the rest of the line first and the line below it
 * second. Both are ordinary regular expressions; there is no scoring and no
 * nearest-match, because "almost matched" is how a parser quietly invents a
 * rate.
 */
type Rule = {
  key: FieldKey;
  name: string;
  labels: RegExp[];
  value: RegExp;
  clean?: (raw: string) => string | null;
};

const DATE = /((?:0?[1-9]|1[0-2])[/-](?:0?[1-9]|[12]\d|3[01])[/-](?:\d{4}|\d{2})|\d{4}-\d{2}-\d{2})/;
const MONEY = /\$?\s*([0-9][0-9,]*(?:\.\d{1,2})?)/;
const NUMBER = /([0-9][0-9,]*(?:\.\d{1,2})?)/;

/** A US date in any of the shapes a form uses, as an ISO date. */
export function toIsoDate(raw: string): string | null {
  const s = raw.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const m = s.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{2}|\d{4})$/);
  if (!m) return null;
  const [, mm, dd, yy] = m;
  const year = yy.length === 2 ? Number(yy) + 2000 : Number(yy);
  const month = Number(mm);
  const day = Number(dd);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const iso = `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  // Reject the 31st of a thirty-day month rather than rolling it forward.
  const d = new Date(iso + "T00:00:00Z");
  return d.getUTCDate() === day && d.getUTCMonth() + 1 === month ? iso : null;
}

const numeric = (raw: string) => raw.replace(/,/g, "").trim() || null;

const RULES: Rule[] = [
  {
    key: "authNumber",
    name: "authorization number",
    labels: [/authorization\s*(?:#|no\.?|number)?/i, /\bauth\s*(?:#|no\.?|number)/i],
    value: /([A-Z]{0,4}[-\s]?\d[\d-]{3,})/,
    clean: (v) => v.replace(/\s+/g, "").replace(/-$/, ""),
  },
  {
    key: "clientName",
    name: "client name",
    labels: [/client\s*name/i, /^client\b/i, /participant\s*name/i, /consumer\s*name/i],
    value: /([A-Za-z][A-Za-z'’.-]*(?:\s+[A-Za-z][A-Za-z'’.-]*){1,3})/,
  },
  {
    key: "agencyId",
    name: "USOR ID",
    labels: [/usor\s*(?:id|#)/i, /client\s*(?:id|#)/i, /case\s*(?:id|#|number)/i],
    value: /([A-Z]{0,3}\d{4,})/,
    clean: (v) => v.replace(/\s+/g, ""),
  },
  {
    key: "serviceType",
    name: "service",
    labels: [/service\s*(?:type|provided|authorized)?/i, /^service\b/i],
    value: /([A-Za-z][A-Za-z()+\-/ ]{3,60})/,
    clean: (v) => v.replace(/\s{2,}/g, " ").trim(),
  },
  {
    key: "totalHours",
    name: "authorized hours",
    labels: [/(?:total|authorized|approved)\s*(?:units|hours|hrs)/i, /\bhours\s*authorized/i],
    value: NUMBER,
    clean: numeric,
  },
  {
    key: "rate",
    name: "rate",
    labels: [/(?:hourly\s*)?rate/i, /rate\s*per\s*(?:hour|unit)/i, /fee\b/i],
    value: MONEY,
    clean: numeric,
  },
  {
    key: "startDate",
    name: "start date",
    labels: [/(?:start|begin(?:ning)?|effective|from)\s*date/i, /\bstart\b/i],
    value: DATE,
    clean: toIsoDate,
  },
  {
    key: "endDate",
    name: "end date",
    labels: [/(?:end|expiration|expires?|through|to)\s*date/i, /\bend\b/i],
    value: DATE,
    clean: toIsoDate,
  },
  {
    key: "counselorName",
    name: "counselor",
    labels: [/counselor(?:\s*name)?/i, /vr\s*counselor/i],
    value: /([A-Za-z][A-Za-z'’.-]*(?:\s+[A-Za-z][A-Za-z'’.-]*){1,3})/,
  },
  {
    key: "office",
    name: "office",
    labels: [/office/i, /district/i],
    value: /([A-Za-z][A-Za-z ]{2,40})/,
    clean: (v) => v.trim(),
  },
];

/** Fields an authorization cannot be created without. */
export const REQUIRED: FieldKey[] = ["clientName", "serviceType", "rate"];

function applyRule(rule: Rule, lines: string[]): Found | null {
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    for (const label of rule.labels) {
      const at = line.match(label);
      if (!at || at.index === undefined) continue;

      const rest = line.slice(at.index + at[0].length);

      // A label is a label because of where it sits: at the start of its line,
      // or with a colon after it. Without this, "OFFICE" inside "UTAH STATE
      // OFFICE OF REHABILITATION" is a label and the office reads as "OF
      // REHABILITATION" — which is exactly what it did the first time this
      // was run.
      const labelled = at.index === 0 || /^\s*[:.]/.test(rest);
      if (!labelled) continue;

      // The rest of the line, past the label and any separator.
      const after = rest.replace(/^[\s:.—-]+/, "");
      const here = after.match(rule.value);
      if (here) {
        const value = rule.clean ? rule.clean(here[1]) : here[1].trim();
        if (value) return { value, source: line, rule: rule.name };
      }

      // Then the line below, for forms that put the label above the box.
      const below = lines[i + 1];
      if (below && !RULES.some((r) => r.labels.some((l) => l.test(below)))) {
        const under = below.match(rule.value);
        if (under) {
          const value = rule.clean ? rule.clean(under[1]) : under[1].trim();
          if (value) return { value, source: `${line} ⏎ ${below}`, rule: rule.name };
        }
      }
    }
  }
  return null;
}

export function parseAuthorizationText(
  plain: string,
  meta: { pages: number; scanned: boolean },
): ParsedAuthorization {
  const lines = plain
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);

  const fields: Partial<Record<FieldKey, Found>> = {};
  const warnings: string[] = [];

  if (meta.scanned) {
    return {
      fields,
      missing: RULES.map((r) => r.key),
      warnings: [
        "This file has no text in it — it is a scan or a photograph. Reading those needs optical character recognition, which is not built yet, so type the authorization in by hand for now.",
      ],
      scanned: true,
      pages: meta.pages,
      lines,
    };
  }

  for (const rule of RULES) {
    const found = applyRule(rule, lines);
    if (found) fields[rule.key] = found;
  }

  // ── what the rules cannot decide ────────────────────────────
  // Hourly or flat fee changes what the authorization means, and the form does
  // not always say. Hours present and a rate that looks like an hourly rate is
  // the usual signal; anything else is left for the person to answer.
  const hours = fields.totalHours ? Number(fields.totalHours.value) : null;
  if (hours && hours > 0) {
    fields.rateType = { value: "Hourly", source: "hours are authorized", rule: "rate type" };
  } else if (fields.rate) {
    fields.rateType = {
      value: "Flat Fee",
      source: "a fee with no hours against it",
      rule: "rate type",
    };
  }

  // ── things worth saying out loud ────────────────────────────
  if (fields.startDate && fields.endDate) {
    if (fields.endDate.value < fields.startDate.value) {
      warnings.push(
        `The end date read as ${fields.endDate.value}, which is before the start date ${fields.startDate.value}. One of the two has been picked up from the wrong box.`,
      );
    }
  }
  if (fields.rate && Number(fields.rate.value) > 10000) {
    warnings.push(
      `The rate read as ${fields.rate.value}, which is high enough to be a total rather than a rate. Check it against the form.`,
    );
  }
  if (fields.totalHours && Number(fields.totalHours.value) > 2000) {
    warnings.push(
      `${fields.totalHours.value} hours is more than a working year. Check whether that figure is hours or something else.`,
    );
  }

  const missing = RULES.map((r) => r.key).filter((k) => !fields[k]);

  return { fields, missing, warnings, scanned: false, pages: meta.pages, lines };
}
