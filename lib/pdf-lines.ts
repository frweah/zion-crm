/**
 * Words on a page, grouped into lines.
 *
 * Pure, and kept apart from the pdf.js call so it can be checked without one:
 * this is where a form stops being a cloud of positioned words and becomes
 * something a rule can read, and it is the part most likely to be wrong on a
 * layout nobody has seen yet.
 */

export type PdfWord = { x: number; y: number; text: string };

export type PdfLine = {
  page: number;
  /** Distance from the top of the page, in points. */
  y: number;
  x: number;
  text: string;
};

/** Two words are on the same line when their baselines are this close. */
export const LINE_TOLERANCE = 3;

export function groupIntoLines(words: PdfWord[], page: number): PdfLine[] {
  const items = [...words].sort((a, b) => a.y - b.y || a.x - b.x);
  const lines: PdfLine[] = [];
  let current: PdfWord[] = [];

  const flush = () => {
    if (current.length === 0) return;
    const sorted = [...current].sort((a, b) => a.x - b.x);
    lines.push({
      page,
      y: Math.round(sorted[0].y),
      x: Math.round(sorted[0].x),
      text: sorted
        .map((i) => i.text)
        .join(" ")
        .replace(/\s{2,}/g, " ")
        .trim(),
    });
    current = [];
  };

  for (const item of items) {
    if (current.length > 0 && Math.abs(item.y - current[0].y) > LINE_TOLERANCE) flush();
    current.push(item);
  }
  flush();

  return lines;
}
