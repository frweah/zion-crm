/**
 * Authorization numbers, compared the way the database compares them.
 *
 * public.normalize_auth_number does the same in SQL, and the unique index on
 * authorizations is built on it. The two must agree, or a document could be
 * matched here to a number the database considers different — or missed for
 * one it considers the same.
 *
 * No imports, so a check script can run it directly.
 */

/** Upper case, letters and digits only. "z-990 0001" is "Z9900001". */
export function normalizeAuthNumber(value: string | null | undefined): string {
  return String(value ?? "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
}

export type AuthOnFile = {
  id: string;
  number: string;
  status: string;
  start_date: string | null;
  end_date: string | null;
};

export type Mention = AuthOnFile & {
  /** Read off the form's own number field, or only found somewhere in the text. */
  how: "number read" | "number appears";
};

/**
 * Which of a client's authorizations a document is about.
 *
 * Two ways, the first preferred: the number the parser read off the form
 * equals one on file; or a number on file appears somewhere in the text.
 * The second exists because a known number is far more reliable than any
 * label — in the first real backfill the parser read the number off none of
 * the authorizations, while the number on file appeared in four of five.
 *
 * Tokens are letters-and-digits runs, and each adjacent pair is tried joined,
 * so "Z 9900001" is found and "XZ99000012" is not mistaken for Z9900001.
 * Numbers under six characters are skipped: too short to be sure of.
 */
export function authorizationsMentioned(
  text: string,
  parsedNumber: string | null | undefined,
  onFile: AuthOnFile[],
): Mention[] {
  const read = normalizeAuthNumber(parsedNumber);
  const tokens = text.toUpperCase().match(/[A-Z0-9]+/g) ?? [];
  const present = new Set(tokens);
  for (let i = 0; i + 1 < tokens.length; i++) present.add(tokens[i] + tokens[i + 1]);

  const found: Mention[] = [];
  for (const a of onFile) {
    const key = normalizeAuthNumber(a.number);
    if (key.length < 6) continue;
    if (read && key === read) found.push({ ...a, how: "number read" });
    else if (present.has(key)) found.push({ ...a, how: "number appears" });
  }
  return found;
}
