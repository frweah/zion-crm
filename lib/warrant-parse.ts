/**
 * A USOR warrant stub, read.
 *
 * One page per warrant. Its lines each pay one invoice:
 *
 *   Dept   Voucher #        Invoice #/Description                                              Amount
 *   630    26PR00001234567  V0000101B / 123456-A Sample-V0000101B-DOS 07/09/2025-560.00         560.00
 *
 * and its foot gives the warrant number, date and total. The text is OCR, so
 * a line may wrap, a slash may lose its spaces, and a number may be misread.
 * This reads what is there and says what it could not find; it does not
 * correct anything. Whether the page is right - both copies of a V-number
 * agree, the lines add up to the total - is decided in the database
 * (public.reconcile_warrant_line), where the answer is kept with the line.
 *
 * No imports, so scripts/check-warrant-parse.mjs can run it directly.
 */

export type WarrantLine = {
  lineNo: number;
  raw: string;
  dept: string;
  voucher: string;
  /** The V-number before the slash, as read (spaces removed, upper case). */
  invoiceRef: string;
  /** The V-number inside the description. */
  describedRef: string;
  clientCode: string;
  clientName: string;
  serviceDate: string | null;
  describedAmount: number | null;
  amount: number | null;
};

export type WarrantPage = {
  warrantNo: string;
  warrantDate: string | null;
  total: number | null;
  lines: WarrantLine[];
  problems: string[];
};

const MONEY = /\$?\s*(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2})\b/;
// A letter O is accepted where the digits go - OCR reads 0 as O - so the line
// is still found. It is kept as read: "VO000903A" stays that, the two copies on
// the line then disagree, and the line waits for a person with the page image
// rather than being corrected here.
const VNUM = String.raw`V\s?[\dO]{6,7}(?:\s?[A-Z](?![A-Z]))?`;

function money(s: string | undefined): number | null {
  if (!s) return null;
  const m = s.match(MONEY);
  return m ? Number(`${m[1].replace(/,/g, "")}.${m[2]}`) : null;
}

function isoDate(raw: string | undefined): string | null {
  if (!raw) return null;
  const m = raw.match(/(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})/);
  if (!m) return null;
  const year = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
  const month = Number(m[1]);
  const day = Number(m[2]);
  if (month < 1 || month > 12 || day < 1 || day > 31 || year < 2000 || year > 2100) return null;
  const d = new Date(Date.UTC(year, month - 1, day));
  if (d.getUTCMonth() !== month - 1) return null;
  return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

const ref = (s: string) => s.toUpperCase().replace(/\s+/g, "");

// The description: 6 digits - initial surname - V-number [-DOS date] - amount.
// On real stubs the V-number is sometimes printed twice in the description
// ("Name-V0000663-V0000663-585.00") where a DOS would go; every copy is read.
const DESCRIPTION = new RegExp(
  // The initial is not checked against anything, and OCR reads an O as 0.
  String.raw`(\d{6})\s*-\s*([A-Za-z0-9])\.?\s*([A-Za-z][A-Za-z' .]*(?:-[A-Za-z][A-Za-z' .]*)*?)\s*-\s*(${VNUM}(?:\s*-\s*${VNUM})*)` +
    String.raw`\s*(?:-\s*DOS\s*(\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}))?\s*-\s*\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})`,
  "i",
);
const INVOICE_REF = new RegExp(String.raw`(${VNUM})\s*/\s*$`, "i");

export function parseWarrantPage(text: string): WarrantPage {
  const problems: string[] = [];
  const rows = text
    .replace(/\r/g, "")
    .split("\n")
    .map((l) => l.replace(/[|]/g, " ").replace(/\s+/g, " ").trim())
    .filter(Boolean);

  // A line that starts a description but has no amount after it has wrapped:
  // join it to the next line before reading it.
  const joined: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    let row = rows[i];
    while (
      /\d{6}\s*-\s*[A-Z]/i.test(row) &&
      !DESCRIPTION.test(row) &&
      i + 1 < rows.length &&
      !/warrant|total/i.test(rows[i + 1])
    ) {
      row = `${row} ${rows[++i]}`;
    }
    joined.push(row);
  }

  const lines: WarrantLine[] = [];
  for (const row of joined) {
    const d = row.match(DESCRIPTION);
    if (!d || d.index === undefined) {
      // A row that is plainly a payment line - a voucher number, or "/ 123456-"
      // - but could not be read whole is kept with what could be read, so it
      // is listed for review beside the page image instead of vanishing.
      const looksLikeLine = /\b\d{2}[A-Z]{2}\d{8,13}\b/i.test(row) || /\/\s*\d{6}\s*-/.test(row);
      if (!looksLikeLine || /warrant\s*(?:no|number|#)|\btotal\b/i.test(row)) continue;
      const refMatch = row.match(new RegExp(String.raw`(${VNUM})\s*/`, "i"));
      const voucher = (row.match(/\b(\d{2}[A-Z]{2}\d{8,13})\b/i) ?? [])[1] ?? "";
      const amounts = [...row.matchAll(/\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})\b/g)];
      const lineNo = lines.length + 1;
      lines.push({
        lineNo,
        raw: row,
        dept: row.split(" ").find((t) => t && t !== voucher && !/\//.test(t)) ?? "",
        voucher: voucher.toUpperCase(),
        invoiceRef: refMatch ? ref(refMatch[1]) : "",
        describedRef: "",
        clientCode: "",
        clientName: "",
        serviceDate: null,
        describedAmount: null,
        amount: amounts.length ? money(amounts[amounts.length - 1][1]) : null,
      });
      problems.push(`line ${lineNo}: could not be read whole`);
      continue;
    }

    const before = row.slice(0, d.index);
    const after = row.slice(d.index + d[0].length);
    const refMatch = before.match(INVOICE_REF);
    const lead = refMatch ? before.slice(0, refMatch.index).trim() : before.trim();
    const voucher = (lead.match(/\b(\d{2}[A-Z]{2}\d{8,13})\b/i) ?? [])[1] ?? "";
    const dept = lead.split(" ").find((t) => t && t !== voucher) ?? "";
    // Every copy in the description. When they differ, all of them are kept,
    // so the line cannot pass as agreeing with the V-number before the slash.
    const copies = [...new Set(d[4].split(/\s*-\s*/).map(ref))];
    const describedRef = copies.join("/");

    lines.push({
      lineNo: lines.length + 1,
      raw: row,
      dept,
      voucher: voucher.toUpperCase(),
      invoiceRef: refMatch ? ref(refMatch[1]) : "",
      describedRef,
      clientCode: d[1],
      clientName: `${d[2].toUpperCase()} ${d[3].trim()}`,
      serviceDate: isoDate(d[5]),
      describedAmount: money(d[6]),
      amount: money(after),
    });
  }

  const flat = rows.join("\n");
  // "WARRANT NO: F 00000407" on the stub; the workbook writes it F00000407.
  const warrantMatch = flat.match(/warrant\s*(?:no|number|#)\.?\s*[:#]?\s*([A-Z]{0,2})\s?(\d{5,12})\b/i);
  const warrantNo = warrantMatch ? `${warrantMatch[1]}${warrantMatch[2]}` : "";
  const dateLine =
    flat.match(/warrant\s*date\s*[:#]?\s*(\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4})/i) ??
    flat.match(/\bdate\s*[:#]?\s*(\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4})/i);
  const totals = [...flat.matchAll(/\btotal\s*(?:amount)?\s*[:#]?\s*\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})/gi)];

  const page: WarrantPage = {
    warrantNo: warrantNo.toUpperCase(),
    warrantDate: isoDate(dateLine?.[1]),
    total: totals.length ? money(totals[totals.length - 1][1]) : null,
    lines,
    problems,
  };

  // Each amount is printed twice: at the end of the description, and in the
  // Amount column. On real stubs the column is set in a different face and OCR
  // garbles it ("2, 250.00", "L.:12:0'.:0:0", 1,126.00 for 1,120.00), while the
  // description's copy reads true. The page total decides which reading holds:
  // the column when it adds up to the total; otherwise the description's
  // amounts, but only if those add up to the total exactly. When neither does,
  // the column stands and the page goes to review.
  const cents = (n: number | null) => (n === null ? null : Math.round(n * 100));
  const sumCents = (xs: (number | null)[]) => (xs.some((x) => x === null) ? null : xs.reduce<number>((s, x) => s + (cents(x) as number), 0));
  const target = cents(page.total);
  if (target !== null && lines.length) {
    const column = sumCents(lines.map((l) => l.amount));
    const described = sumCents(lines.map((l) => l.describedAmount));
    if (column !== target && described === target) {
      const misread = lines.filter((l) => cents(l.amount) !== cents(l.describedAmount)).map((l) => l.lineNo);
      for (const l of lines) l.amount = l.describedAmount;
      if (misread.length) {
        problems.push(
          `amount column misread on line${misread.length === 1 ? "" : "s"} ${misread.join(", ")}; the description's amounts were used, and they add up to the total`,
        );
      }
    }
  }

  if (!page.warrantNo) problems.push("no warrant number read");
  if (!page.warrantDate) problems.push("no warrant date read");
  if (page.total === null) problems.push("no total read");
  if (lines.length === 0) problems.push("no lines read");
  for (const l of lines) {
    if (!l.invoiceRef) problems.push(`line ${l.lineNo}: no V-number before the slash`);
    if (l.amount === null) problems.push(`line ${l.lineNo}: no amount`);
  }
  if (problems.some((p) => p.startsWith("amount column misread"))) {
    // The "no amount" notes were about the column, which was not used.
    for (let i = problems.length - 1; i >= 0; i--) if (/^line \d+: no amount$/.test(problems[i])) problems.splice(i, 1);
  }
  return page;
}

/** The sum of the amounts read, to the cent. Null when any line has no amount. */
export function linesTotal(page: WarrantPage): number | null {
  if (page.lines.some((l) => l.amount === null)) return null;
  return Math.round(page.lines.reduce((s, l) => s + (l.amount ?? 0), 0) * 100) / 100;
}
