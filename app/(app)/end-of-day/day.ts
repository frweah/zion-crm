/**
 * The shapes the end-of-day screen and its actions share.
 *
 * Its own file because a "use server" module may export nothing but async
 * functions, and a list of statuses and a parser are neither.
 */

export const STATUSES = ["Complete", "In-Progress", "Pending"] as const;
export type DayStatus = (typeof STATUSES)[number];

/**
 * As long as a field of a day's report is allowed to be.
 *
 * Not a rule about writing, which is why it is this generous: the practice's
 * own template is a handful of lines and nobody will reach four thousand
 * characters by describing their day. It is there so that a whole document
 * pasted into Notes by accident is refused in a sentence rather than carried
 * into every email the day is sent in.
 */
export const KEPT_LIMIT = 4000;

/**
 * Text kept as it was typed (owner, 23 Oct 2026, from Rei's feedback).
 *
 * The fields of a day's report used to be trimmed, which is the normal and
 * usually right thing to do to a form field - and wrong here. Somebody
 * writing up their day indents a sub-point under the task it belongs to, and
 * `trim()` ate the indentation of the first line and every blank line at the
 * end. What they typed is what the practice keeps.
 *
 * Two things are still done to it, and neither changes what anybody typed:
 *
 *   **CRLF becomes LF.** A browser posts a textarea's line breaks as CRLF
 *   whatever the person's keyboard did - it is in the HTML specification -
 *   so storing it raw would mean the text that comes back differs from the
 *   text that went in. One newline everywhere is what makes "unchanged"
 *   checkable at all.
 *
 *   **A field of nothing but whitespace becomes empty**, so that an empty
 *   Notes box does not become four spaces on a client's record. A field with
 *   any content keeps its leading and trailing whitespace exactly.
 */
export function keepAsTyped(raw: unknown): string {
  const text = String(raw ?? "").replace(/\r\n?/g, "\n");
  if (text.trim() === "") return "";
  return text;
}

/** Whether a field somebody has to fill in has anything in it. */
export function hasWords(text: string): boolean {
  return text.trim() !== "";
}

/** Whether it is over the limit, in the words the screen says it in. */
export function tooLong(text: string, field: string): string | null {
  return text.length > KEPT_LIMIT
    ? `${field} is ${text.length} characters. The limit is ${KEPT_LIMIT} — put the detail on the client's record and say where it is.`
    : null;
}

/**
 * A pasted report, split into lines.
 *
 * People write their day in an email or a notes app before they write it
 * anywhere else, and the practice's own template is a list of hyphens. So a
 * paste is read rather than retyped: every line that starts with a hyphen is
 * a task, and anything before the first hyphen is the heading somebody
 * pasted along with it.
 *
 * A status in brackets at the front is honoured — "- [Pending] ring the
 * counselor" — because that is how the summary this app sends writes them
 * out, so yesterday's email pastes back in.
 *
 * A number counts as a bullet (owner, 23 Oct 2026): "1." and "2)" are how
 * half the practice writes a list, and a paste that silently read none of it
 * was indistinguishable from a paste that had not worked.
 */
const BULLET = /^(?:[-–—*•]|\d{1,3}[.)])\s*/;

export function splitPastedReport(text: string): { status: DayStatus; description: string }[] {
  const out: { status: DayStatus; description: string }[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!BULLET.test(line)) continue;
    let body = line.replace(BULLET, "").trim();
    if (!body) continue;

    let status: DayStatus = "Complete";
    const tagged = body.match(/^\[\s*([A-Za-z-/ ]+?)\s*\]\s*(.*)$/);
    if (tagged) {
      // Hyphens too. The status is literally "In-Progress" and the summary
      // writes it out as "[In-Progress]", so stripping only spaces and
      // slashes left "in-progress", which starts with no word below and came
      // back as Complete - the one form that was certain to be pasted in was
      // the one form that did not read (found by scripts/check-kept-text.mjs,
      // 23 Oct 2026).
      const said = tagged[1].toLowerCase().replace(/[\s/-]/g, "");
      if (said.startsWith("inprogress")) status = "In-Progress";
      else if (said.startsWith("pending") || said.startsWith("todo")) status = "Pending";
      else if (said.startsWith("complete") || said.startsWith("done")) status = "Complete";
      body = tagged[2].trim();
    }
    if (body) out.push({ status, description: body });
  }
  return out;
}
