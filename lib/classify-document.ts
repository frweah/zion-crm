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
  /**
   * A referral: the document that starts a case (Intake Automation Brief,
   * Rule 1). Not a kind of its own, because what it *is* is a USOR form -
   * 94 or 98 - and the kinds are what the document inbox stores and files by.
   * This is the one extra question intake asks of the same answer, so that
   * creating a client never depends on a second classifier.
   */
  referral?: boolean;
  /**
   * For a USOR 94 or 98: whether its assessment half has been written on, and
   * so whether this copy is a referral arriving or an assessment coming back.
   * See `assessmentBody`.
   */
  assessment?: AssessmentBody;
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

/**
 * The forms that can start a case: USOR 94 and USOR 98. A WSA referral names
 * neither and says so in words instead.
 *
 * Being one of these is necessary and not sufficient, which is the whole of
 * `assessmentBody` below. DWS-USOR 94 is the Work Strategy Assessment and it
 * is the same sheet of paper twice: the counselor sends it with the client's
 * details filled in and the assessment blank, and the CRP sends it back with
 * the assessment written on it. The practice's own filing says as much -
 * "94 (WSA Referral - editable)" and "WSA form 94 ZZ Testperson complete" are in
 * the same folder.
 *
 * So the form number says which form, and the state of its assessment body
 * says which direction it is going. Treating every 94 as a referral means
 * every completed assessment coming back is read as a new client arriving.
 */
const REFERRAL_FORMS = ["94", "98"];
const WSA_REFERRAL = /\bwsa\b.{0,40}\breferral\b|\breferral\b.{0,40}\bwsa\b/is;

/**
 * Whether the assessment half of a 94 has been written on.
 *
 * `none`      - the form has no assessment section at all. A USOR 98 is this:
 *               it is titled REFERRAL FOR CRP ASSESSMENT and carries only the
 *               counselor's description of the client.
 * `blank`     - the boxes are there and every one of them is empty. A referral.
 * `completed` - the boxes are there and written in. An assessment coming back.
 * `unclear`   - one or two filled, which is neither shape. Nothing is guessed
 *               from it: see `classifyDocument`.
 *
 * Measured against six real documents - one referral, three completed 94s and
 * two 98s - and the separation is not close: 0 boxes filled on the referral,
 * 7, 13 and 13 on the completed ones.
 */
export type AssessmentBody = "none" | "blank" | "completed" | "unclear";

/**
 * The boxes a CRP fills in and a counselor leaves empty.
 *
 * Only the assessment half. The referral half of a 94 - current work skills,
 * family supports, communication needs - arrives filled in, because that is
 * the counselor telling the practice about the client, so reading those boxes
 * would call every referral a completed report.
 */
const ASSESSMENT_BOXES = [
  /^other observations\s*:/,
  /^observations\s*:/,
  /^planned job search hours\/week\s*:/,
  /^life skills needed\s*:/,
  /^life skills hours requested\s*:/,
  /^recommended target occupations\s*:/,
  /^recommended supports on the job\s*:/,
  /^joint vr\/crp recommendations/,
  /^job goal\b/,
  /^community rehabilitation program name\s*:/,
  /^assigned employment specialist/,
];

/**
 * The three signature lines.
 *
 * Counted and reported, never relied on. Of the three completed 94s measured,
 * one had two signatures in the text and two had none - they are signed with
 * an image, or on paper, and a PDF's text says nothing about either. A rule
 * resting on signatures would have called two completed assessments blank.
 */
const SIGNATURE_LINES = [
  /^client signature\s*:/,
  /^crp signature\s*:/,
  /^vr counselor signature\s*:/,
];

/**
 * A line that is the form talking, not somebody answering it.
 *
 * The assessment sections head themselves with how long they take - "Natural
 * Support Assessment (1 hour)", "Transportation Assessment (30 min)" - which
 * is the one mark that separates a heading from a paragraph here. Prose is no
 * use for it: the headings print their checkbox labels on the same line, and
 * "Interpersonal skills How the client reacts to criticism" has as many
 * ordinary words in it as a real answer would.
 */
const FORM_TALKING =
  /\(\s*\d+(?:\.\d+)?\s*(?:hours?|hrs?|mins?|minutes?)\s*\)|^(?:recommendations|team section)\b|^acre certified\b|^print\s+reset\s+save/i;

export function assessmentBody(text: string): {
  state: AssessmentBody;
  boxes: number;
  filled: number;
  signed: number;
} {
  const lines = text
    .split("\n")
    .map((l) => l.replace(/\s+/g, " ").trim())
    .filter(Boolean);

  let boxes = 0;
  let filled = 0;
  let signed = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const low = line.toLowerCase();
    const isBox = ASSESSMENT_BOXES.some((r) => r.test(low));
    const isSig = !isBox && SIGNATURE_LINES.some((r) => r.test(low));
    if (!isBox && !isSig) continue;

    // What is written in the box: after the colon on the label's own line, or
    // on the line below where the form prints the label above the space.
    const at = line.indexOf(":");
    const rest = at < 0 ? "" : line.slice(at + 1).trim();
    const here = Boolean(rest) && !rest.endsWith(":") && !FORM_TALKING.test(rest);

    const next = lines[i + 1] ?? "";
    const below = Boolean(next) && !next.endsWith(":") && !FORM_TALKING.test(next);

    if (isBox) {
      boxes++;
      if (here || below) filled++;
    } else if (here || below) {
      signed++;
    }
  }

  // One stray match is not an assessment section. A 98 has none of these boxes
  // and one line that happens to read like the last of them.
  const state: AssessmentBody =
    boxes <= 1 ? "none" : filled === 0 ? "blank" : filled >= 3 ? "completed" : "unclear";

  return { state, boxes, filled, signed };
}

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
    const number = seen[0].replace(/\D/g, "");
    if (!REFERRAL_FORMS.includes(number)) {
      return { kind: "USOR form", reason: `names ${seen[0]} and nothing else`, usor: seen[0], seen };
    }

    // A form that can start a case. Whether this copy of it is starting one
    // depends on which way it is travelling, which its assessment body says.
    const body = assessmentBody(text);
    const how = `${seen[0]}, ${body.filled} of ${body.boxes} assessment boxes written in`;

    return {
      kind: "USOR form",
      usor: seen[0],
      seen,
      assessment: body.state,
      // Only a form with nothing written in its assessment is a referral. A
      // completed one is the assessment coming back and must never create a
      // client; an unclear one is not read either way, which is the point.
      referral: body.state === "none" || body.state === "blank",
      reason:
        body.state === "none"
          ? `${seen[0]} has no assessment section, so it is the referral form itself`
          : body.state === "blank"
            ? `${how} — a referral, sent for the assessment to be done`
            : body.state === "completed"
              ? `${how} — the completed assessment coming back, not a new referral`
              : `${how} — neither a blank referral nor a completed assessment, so it is not read as either`,
    };
  }

  const auth = AUTHORIZATION_MARKS.find((r) => r.test(text));
  if (auth) {
    return { kind: "Authorization", reason: `matched ${auth.source}`, seen };
  }

  // A WSA referral last, and only once nothing else has claimed the document.
  // It is recognised by words rather than by a form number, which is the
  // weakest kind of mark there is - so it answers for a document that is
  // otherwise "Other" and never takes one from an authorization or a form.
  if (WSA_REFERRAL.test(text)) {
    return {
      kind: "USOR form",
      reason: "reads as a WSA referral, naming no USOR form",
      seen,
      referral: true,
    };
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
