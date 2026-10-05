import "server-only";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import { ORG } from "@/lib/roles";

/**
 * A statement of hours worked, on one page where it fits: who, over what
 * dates, every session with its date, category, client and hours, the total,
 * and a line for the employer to sign (Rei, Oct 2026).
 *
 * The signature line is the point of the document. The CRM already knows what
 * was worked; what it could not produce was the piece of paper somebody signs
 * to say so, and that is what a contractor's invoice and an employee's pay
 * both rest on.
 *
 * It states the hours and never a rate or a sum of money: what an hour is
 * worth is between the practice and the person, it lives on their pay record,
 * and a figure printed here would be read as a claim for payment.
 */
export type StatementSession = {
  worked_on: string;
  hours: number;
  category: string | null;
  client_name: string | null;
  description: string | null;
  voided: boolean;
};

const PAGE = { width: 612, height: 792 };
const MARGIN = 54;
const WIDTH = PAGE.width - MARGIN * 2;

function printable(text: string): string {
  return text
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, "-")
    .replace(/…/g, "...")
    .replace(/[^\x20-\x7E\xA0-\xFF]/g, "");
}

function clip(text: string, font: PDFFont, size: number, width: number): string {
  let out = printable(text);
  if (font.widthOfTextAtSize(out, size) <= width) return out;
  while (out.length > 1 && font.widthOfTextAtSize(out + "...", size) > width) out = out.slice(0, -1);
  return out + "...";
}

const money = (n: number) => n.toFixed(2);

export async function statementPdf({
  staffName,
  from,
  to,
  sessions,
  preparedOn,
}: {
  staffName: string;
  from: string;
  to: string;
  sessions: StatementSession[];
  preparedOn: string;
}): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const body = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const ink = rgb(0.12, 0.11, 0.1);
  const soft = rgb(0.44, 0.42, 0.38);

  let page: PDFPage = pdf.addPage([PAGE.width, PAGE.height]);
  let y = PAGE.height - MARGIN;

  const line = (text: string, size: number, font: PDFFont, colour = ink, dy = 16) => {
    page.drawText(printable(text), { x: MARGIN, y, size, font, color: colour });
    y -= dy;
  };

  line(ORG.name, 15, bold, ink, 20);
  line("Statement of hours worked", 12, body, soft, 22);
  line(staffName, 13, bold, ink, 16);
  line(`${from} to ${to}`, 11, body, soft, 24);

  // ── the sessions ──────────────────────────────────────────
  const cols = [MARGIN, MARGIN + 74, MARGIN + 184, MARGIN + 324, MARGIN + WIDTH - 44];
  const header = () => {
    page.drawText("Date", { x: cols[0], y, size: 9, font: bold, color: soft });
    page.drawText("Category", { x: cols[1], y, size: 9, font: bold, color: soft });
    page.drawText("Client", { x: cols[2], y, size: 9, font: bold, color: soft });
    page.drawText("What was done", { x: cols[3], y, size: 9, font: bold, color: soft });
    page.drawText("Hours", { x: cols[4], y, size: 9, font: bold, color: soft });
    y -= 6;
    page.drawLine({ start: { x: MARGIN, y }, end: { x: MARGIN + WIDTH, y }, thickness: 0.5, color: soft });
    y -= 14;
  };
  header();

  let total = 0;
  for (const s of sessions) {
    if (y < MARGIN + 150) {
      page = pdf.addPage([PAGE.width, PAGE.height]);
      y = PAGE.height - MARGIN;
      header();
    }
    const struck = s.voided;
    const colour = struck ? soft : ink;
    page.drawText(printable(s.worked_on), { x: cols[0], y, size: 9.5, font: body, color: colour });
    page.drawText(clip(s.category ?? "-", body, 9.5, 104), { x: cols[1], y, size: 9.5, font: body, color: colour });
    page.drawText(clip(s.client_name ?? "-", body, 9.5, 134), { x: cols[2], y, size: 9.5, font: body, color: colour });
    page.drawText(clip((s.description ?? "") + (struck ? " (corrected)" : ""), body, 9.5, cols[4] - cols[3] - 8), {
      x: cols[3],
      y,
      size: 9.5,
      font: body,
      color: colour,
    });
    const hours = struck ? "-" : money(s.hours);
    page.drawText(hours, {
      x: MARGIN + WIDTH - body.widthOfTextAtSize(hours, 9.5),
      y,
      size: 9.5,
      font: body,
      color: colour,
    });
    if (!struck) total += s.hours;
    y -= 14;
  }

  y -= 4;
  page.drawLine({ start: { x: MARGIN, y }, end: { x: MARGIN + WIDTH, y }, thickness: 0.5, color: soft });
  y -= 16;
  page.drawText("Total hours", { x: cols[3], y, size: 11, font: bold, color: ink });
  const totalText = money(total);
  page.drawText(totalText, {
    x: MARGIN + WIDTH - bold.widthOfTextAtSize(totalText, 11),
    y,
    size: 11,
    font: bold,
    color: ink,
  });
  y -= 40;

  // ── the signatures ────────────────────────────────────────
  if (y < MARGIN + 120) {
    page = pdf.addPage([PAGE.width, PAGE.height]);
    y = PAGE.height - MARGIN;
  }

  const rule = (label: string, x: number, width: number) => {
    page.drawLine({ start: { x, y }, end: { x: x + width, y }, thickness: 0.75, color: ink });
    page.drawText(label, { x, y: y - 12, size: 9, font: body, color: soft });
  };

  const half = (WIDTH - 30) / 2;
  page.drawText("I certify that the hours above are a true record of work performed.", {
    x: MARGIN,
    y: y + 34,
    size: 10,
    font: body,
    color: ink,
  });
  rule("Employee signature", MARGIN, half);
  rule("Date", MARGIN + half + 30, half);
  y -= 56;
  rule("Employer signature", MARGIN, half);
  rule("Date", MARGIN + half + 30, half);
  y -= 34;

  page.drawText(`Prepared ${printable(preparedOn)} from the Zion Voc Rehab CRM.`, {
    x: MARGIN,
    y,
    size: 8.5,
    font: body,
    color: soft,
  });

  return pdf.save();
}
