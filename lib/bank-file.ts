/**
 * Reading a bank statement the owner downloaded (ERP brief, E1).
 *
 * CSV and OFX, because those are what a bank offers and because both are
 * text: no credentials, no connection, nothing that can move money. The file
 * is whatever the bank decided to call its columns this year, so the parser
 * recognises them by name rather than by position - a statement whose columns
 * moved would otherwise import amounts into the date field and look fine.
 *
 * What this does not do is decide anything. It returns lines; a person
 * decides what each one was.
 */

export type StatementLine = {
  posted_on: string;
  description: string;
  /** Signed as a statement reads: money in positive, money out negative. */
  amount: number;
  external_id: string;
};

export type ParsedStatement = {
  lines: StatementLine[];
  /** From the file where it says, for the person to confirm. */
  closing: number | null;
  problems: string[];
};

const NAMES = {
  date: ["date", "posted", "posted date", "post date", "transaction date", "effective date"],
  description: ["description", "name", "memo", "payee", "details", "transaction"],
  amount: ["amount", "transaction amount"],
  debit: ["debit", "withdrawal", "withdrawals", "money out", "paid out"],
  credit: ["credit", "deposit", "deposits", "money in", "paid in"],
  id: ["id", "fitid", "transaction id", "reference", "check number", "cheque number"],
};

/** A date in whatever order the bank wrote it, as an ISO day. */
function isoDate(raw: string): string | null {
  const text = raw.trim();
  let m = text.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = text.match(/^(\d{4})(\d{2})(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  // Month first, which is what a US bank means by 03/04/2026.
  m = text.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})/);
  if (m) {
    const year = m[3].length === 2 ? `20${m[3]}` : m[3];
    return `${year}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}`;
  }
  return null;
}

/** A number with whatever a bank puts around it: $, commas, brackets, CR. */
function amount(raw: string): number | null {
  let text = raw.trim().replace(/[$\s,]/g, "");
  if (!text) return null;
  let sign = 1;
  if (/^\(.*\)$/.test(text)) {
    sign = -1;
    text = text.slice(1, -1);
  }
  if (/^-/.test(text)) {
    sign = -1;
    text = text.slice(1);
  }
  if (/(dr|debit)$/i.test(text)) {
    sign = -1;
    text = text.replace(/(dr|debit)$/i, "");
  } else if (/(cr|credit)$/i.test(text)) {
    text = text.replace(/(cr|credit)$/i, "");
  }
  const n = Number(text);
  return Number.isFinite(n) ? sign * n : null;
}

/** One CSV row, respecting quotes. */
function splitRow(line: string): string[] {
  const out: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quoted) {
      if (c === '"' && line[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (c === '"') {
        quoted = false;
      } else {
        cell += c;
      }
    } else if (c === '"') {
      quoted = true;
    } else if (c === ",") {
      out.push(cell);
      cell = "";
    } else {
      cell += c;
    }
  }
  out.push(cell);
  return out.map((s) => s.trim());
}

function parseCsv(text: string): ParsedStatement {
  const problems: string[] = [];
  const rows = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean)
    .map(splitRow);

  // The header is the first row that names a date and either an amount or a
  // debit and credit pair. Banks put a preamble above it.
  const match = (cell: string, names: string[]) => names.includes(cell.toLowerCase().trim());
  const headerAt = rows.findIndex(
    (r) =>
      r.some((c) => match(c, NAMES.date)) &&
      (r.some((c) => match(c, NAMES.amount)) ||
        (r.some((c) => match(c, NAMES.debit)) && r.some((c) => match(c, NAMES.credit)))),
  );
  if (headerAt === -1) {
    return {
      lines: [],
      closing: null,
      problems: ["This file has no row naming a date and an amount, so there is nothing to read."],
    };
  }

  const header = rows[headerAt].map((c) => c.toLowerCase().trim());
  const at = (names: string[]) => header.findIndex((c) => names.includes(c));
  const iDate = at(NAMES.date);
  const iText = at(NAMES.description);
  const iAmount = at(NAMES.amount);
  const iDebit = at(NAMES.debit);
  const iCredit = at(NAMES.credit);
  const iId = at(NAMES.id);

  const lines: StatementLine[] = [];
  for (const row of rows.slice(headerAt + 1)) {
    const day = isoDate(row[iDate] ?? "");
    if (!day) continue;
    let value: number | null = null;
    if (iAmount !== -1) {
      value = amount(row[iAmount] ?? "");
    } else {
      const out = amount(row[iDebit] ?? "") ?? 0;
      const inn = amount(row[iCredit] ?? "") ?? 0;
      value = inn - Math.abs(out);
    }
    if (value === null || value === 0) continue;
    lines.push({
      posted_on: day,
      description: (iText === -1 ? "" : row[iText] ?? "").slice(0, 300),
      amount: Math.round(value * 100) / 100,
      external_id: (iId === -1 ? "" : row[iId] ?? "").slice(0, 100),
    });
  }

  if (lines.length === 0) problems.push("No line in this file had both a date and an amount.");
  return { lines, closing: null, problems };
}

function parseOfx(text: string): ParsedStatement {
  const problems: string[] = [];
  const lines: StatementLine[] = [];
  const tag = (block: string, name: string) =>
    (block.match(new RegExp(`<${name}>([^<\r\n]*)`, "i"))?.[1] ?? "").trim();

  for (const block of text.split(/<STMTTRN>/i).slice(1)) {
    const day = isoDate(tag(block, "DTPOSTED"));
    const value = amount(tag(block, "TRNAMT"));
    if (!day || value === null || value === 0) continue;
    lines.push({
      posted_on: day,
      description: (tag(block, "NAME") || tag(block, "MEMO")).slice(0, 300),
      amount: Math.round(value * 100) / 100,
      external_id: tag(block, "FITID").slice(0, 100),
    });
  }

  // The balance the bank states, which is the one worth checking against.
  const balanceBlock = text.match(/<LEDGERBAL>[\s\S]*?<\/LEDGERBAL>|<LEDGERBAL>[\s\S]{0,400}/i)?.[0] ?? "";
  const closing = amount(tag(balanceBlock, "BALAMT"));

  if (lines.length === 0) problems.push("This file has no transactions in it.");
  return { lines, closing, problems };
}

/** Reads a statement file, whichever of the two formats it is. */
export function parseStatement(filename: string, text: string): ParsedStatement {
  const looksOfx = /<STMTTRN>/i.test(text) || /\.(ofx|qfx)$/i.test(filename);
  return looksOfx ? parseOfx(text) : parseCsv(text);
}
