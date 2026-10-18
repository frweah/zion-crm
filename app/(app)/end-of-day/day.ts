/**
 * The shapes the end-of-day screen and its actions share.
 *
 * Its own file because a "use server" module may export nothing but async
 * functions, and a list of statuses and a parser are neither.
 */

export const STATUSES = ["Complete", "In-Progress", "Pending"] as const;
export type DayStatus = (typeof STATUSES)[number];

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
 */
export function splitPastedReport(text: string): { status: DayStatus; description: string }[] {
  const out: { status: DayStatus; description: string }[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!/^[-–—*•]\s*/.test(line)) continue;
    let body = line.replace(/^[-–—*•]\s*/, "").trim();
    if (!body) continue;

    let status: DayStatus = "Complete";
    const tagged = body.match(/^\[\s*([A-Za-z-/ ]+?)\s*\]\s*(.*)$/);
    if (tagged) {
      const said = tagged[1].toLowerCase().replace(/\s|\//g, "");
      if (said.startsWith("inprogress")) status = "In-Progress";
      else if (said.startsWith("pending") || said.startsWith("todo")) status = "Pending";
      else if (said.startsWith("complete") || said.startsWith("done")) status = "Complete";
      body = tagged[2].trim();
    }
    if (body) out.push({ status, description: body });
  }
  return out;
}
