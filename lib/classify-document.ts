/**
 * What kind of document is this?
 *
 * Rules against the text, in a fixed order, the same way lib/authorization-parse
 * reads the fields once a document is known to be an authorization. Nothing
 * scores or guesses: each kind has marks that only that kind carries, and a
 * document showing none of them is "Other" rather than the nearest thing.
 *
 * Getting this wrong is cheap in one direction and expensive in the other. A
 * warrant filed as "Other" is a document somebody has to find. An invoice
 * marked paid because a page mentioned a number is money the practice thinks
 * it has. So the marks for the expensive kinds are the narrow ones.
 *
 * Kept out of the route and free of server-only imports so the check script
 * can run it against text without a PDF.
 */

export type DocumentKind = "Authorization" | "USOR form" | "Warrant" | "Other" | "Unreadable";

export type Classification = {
  kind: DocumentKind;
  /** Which rule decided it, so a wrong answer leads to the rule that gave it. */
  reason: string;
  /** For a USOR form: which one. */
  usor?: string;
  /** For a warrant: what it appears to pay, for matching against invoices. */
  amounts?: number[];
  warrantNumber?: string;
  /** Every USOR number seen, for the record. */
  seen: string[];
};

/** DWS-USOR 93, USOR-95, "DWS USOR 148" — the practice writes it every way. */
const USOR_FORM = /\b(?:DWS[\s-]*)?USOR[\s-]*(\d{2,3})\b/gi;

const AUTHORIZATION_MARKS = [
  // The title USOR prints across the top of its own authorization:
  // "AUTHORIZATION AND INVOICE FOR SERVICE". The one mark nothing else carries.
  /\bauthorization\s+and\s+\w+\s+for\s+services?\b/i,
  /\bauthorization\s*(?:#|no\.?|number)/i,
  /\bauthorization\s+for\s+services\b/i,
  /\bauthorized\s+(?:units|hours)\b/i,
];

const WARRANT_MARKS = [
  /\bwarrant\s*(?:#|no\.?|number)/i,
  /\bremittance\s+advice\b/i,
  /\bpayment\s+advice\b/i,
  /\bvoucher\s*(?:#|no\.?|number)/i,
];

/** Dollar amounts, for proposing which invoice a warrant pays. */
function amountsIn(text: string): number[] {
  const found = new Set<number>();
  for (const m of text.matchAll(/\$\s*([0-9][0-9,]*(?:\.\d{2})?)/g)) {
    const value = Number(m[1].replace(/,/g, ""));
    // Anything under a dollar is a page number with a stray symbol in front
    // of it, and anything over six figures is not a USOR warrant.
    if (value >= 1 && value <= 200000) found.add(value);
  }
  return [...found].sort((a, b) => b - a);
}

export function classifyDocument(text: string): Classification {
  const seen = [...new Set([...text.matchAll(USOR_FORM)].map((m) => `USOR ${m[1]}`))];

  // A scan has no text. Said first, because everything below would otherwise
  // conclude "Other" about a document nobody has read.
  if (text.replace(/\s/g, "").length < 40) {
    return {
      kind: "Unreadable",
      reason: "no text in the file — a scan or a photograph",
      seen,
    };
  }

  // Warrant before authorization: a remittance advice lists the
  // authorizations it is paying, so it carries both sets of marks, and the
  // one that decides what to do with it is the payment.
  const warrant = WARRANT_MARKS.find((r) => r.test(text));
  if (warrant) {
    const number = text.match(/\bwarrant\s*(?:#|no\.?|number)?\s*[:.]?\s*([A-Z0-9-]{4,})/i);
    return {
      kind: "Warrant",
      reason: `matched ${warrant.source}`,
      amounts: amountsIn(text),
      warrantNumber: number ? number[1].replace(/[.,;]$/, "") : undefined,
      seen,
    };
  }

  // A USOR form names itself, and only one of them: a document listing three
  // is an index or a covering letter, not a form.
  //
  // Checked before the authorization marks, because a USOR 95 or 96 has an
  // "Authorization #" box on it. The first real backfill called nine of those
  // forms authorizations for exactly that reason, and a form confirmed as an
  // authorization is a rate on a client's record copied off a monthly report.
  // USOR's own authorizations name no USOR form, so this costs them nothing.
  if (seen.length === 1) {
    return { kind: "USOR form", reason: `names ${seen[0]} and nothing else`, usor: seen[0], seen };
  }

  const auth = AUTHORIZATION_MARKS.find((r) => r.test(text));
  if (auth) {
    return { kind: "Authorization", reason: `matched ${auth.source}`, seen };
  }

  return {
    kind: "Other",
    reason:
      seen.length > 1
        ? `names ${seen.length} USOR forms, so it is not one of them`
        : "none of the marks for an authorization, a warrant or a USOR form",
    seen,
  };
}
