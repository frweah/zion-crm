import { applyFieldRule, toIsoDate, type FieldRule, type Found } from "./authorization-parse.ts";

/**
 * What a referral form says.
 *
 * The same shape as reading an authorization, and deliberately the same
 * machinery: `applyFieldRule` decides what counts as a label and when to look
 * at the line below, which took several passes over real USOR forms to get
 * right. Only the rules differ, because the fields differ.
 *
 * What it does not do is guess. A referral with no name on it is not filed -
 * it is the one document that may create a client, so a name read from the
 * wrong line would create a client called "of Rehabilitation".
 */
export type ReferralField = "clientName" | "counselor" | "office" | "referralDate" | "phone";

export type ParsedReferral = {
  fields: Partial<Record<ReferralField, Found>>;
  missing: ReferralField[];
  lines: string[];
};

const DATE = /((?:0?[1-9]|1[0-2])[/-](?:0?[1-9]|[12]\d|3[01])[/-](?:\d{4}|\d{2})|\d{4}-\d{2}-\d{2})/;

/** A person's name: letters, and the few marks names actually carry. */
const NAME = /([A-Za-z][A-Za-z'’.-]*(?:\s+[A-Za-z][A-Za-z'’.-]*){1,3})/;
const LINE = /(\S.*\S|\S)/;

/** A ten-digit US number, however the form spaces it. */
const PHONE = /(\(?\d{3}\)?[\s.-]*\d{3}[\s.-]*\d{4})/;

const RULES: FieldRule<ReferralField>[] = [
  {
    key: "clientName",
    name: "client name",
    labels: [/\bclient\s*name\b/i, /\bparticipant\s*name\b/i, /\bclient\b/i, /\bname\s+of\s+client\b/i],
    value: NAME,
  },
  {
    key: "counselor",
    name: "counselor",
    labels: [/\bcounselor\b/i, /\bcounsellor\b/i, /\bvr\s*counselor\b/i, /\breferred\s+by\b/i],
    value: NAME,
  },
  {
    key: "office",
    name: "office",
    labels: [/\boffice\b/i, /\bregion\b/i, /\blocation\b/i],
    value: LINE,
    // "Salt Lake City Office" and "Salt Lake City" are the same office, and
    // offices.name holds it without the word.
    clean: (raw) => raw.replace(/\s*office\s*$/i, "").trim() || null,
  },
  {
    key: "referralDate",
    name: "referral date",
    labels: [/\breferral\s*date\b/i, /\bdate\s+of\s+referral\b/i, /\bdate\s+referred\b/i, /\bdate\b/i],
    value: DATE,
    clean: (raw) => toIsoDate(raw),
  },
  {
    key: "phone",
    name: "phone",
    labels: [/\bphone\b/i, /\btelephone\b/i, /\bmobile\b/i, /\bcell\b/i, /\bcontact\s*number\b/i],
    value: PHONE,
  },
];

/** The fields a referral must have for a client to be created from it. */
export const REFERRAL_REQUIRED: ReferralField[] = ["clientName"];

export function parseReferralText(plain: string): ParsedReferral {
  const lines = plain
    .split("\n")
    .map((l) => l.replace(/\s+/g, " ").trim())
    .filter(Boolean);

  const fields: Partial<Record<ReferralField, Found>> = {};
  for (const rule of RULES) {
    if (fields[rule.key]) continue;
    const found = applyFieldRule(rule, lines, RULES);
    if (found) fields[rule.key] = found;
  }

  return {
    fields,
    missing: REFERRAL_REQUIRED.filter((k) => !fields[k]),
    lines,
  };
}
