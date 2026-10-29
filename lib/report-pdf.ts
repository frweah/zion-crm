import "server-only";
import { Pen, fold, printable, type Finished, type Signature } from "@/lib/pdf-page";
import type { MonthlyContent } from "@/lib/report-drafts";
import { monthlyReportLines, type MonthlyMeta } from "@/lib/report-text";

/**
 * The monthly report as the counselor receives it.
 *
 * `monthlyReportLines` is the renderer and this only draws what it returns,
 * the way `signedFormPdf` only draws `formToText`. The screen the owner reads
 * before signing draws the same array, so what was signed is what was read.
 *
 * Set in Helvetica rather than the forms' Courier: the forms lay tables out
 * with spaces and need a monospaced face, and this is prose with a date
 * column, which reads better proportional. The date column is drawn rather
 * than padded for exactly that reason.
 */
export type SignedReport = Finished;

const DATE_COLUMN = 62;

const day = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { day: "numeric", month: "short" });

export async function monthlyReportPdf({
  month,
  content,
  meta,
  signature,
}: {
  month: string;
  content: MonthlyContent;
  meta: MonthlyMeta;
  signature: Signature;
}): Promise<SignedReport> {
  const pen = await Pen.open(`Monthly progress report - ${meta.clientName} - ${month}`);

  for (const line of monthlyReportLines(month, content, meta)) {
    switch (line.as) {
      case "title":
        pen.text(line.text, pen.sansBold, 15, 20);
        pen.gap(2);
        break;
      case "heading":
        pen.text(line.text, pen.sansBold, 10.5, 15);
        break;
      case "label":
        pen.gap(6);
        pen.room(26);
        pen.text(line.text, pen.sansBold, 10, 15);
        pen.rule();
        pen.gap(10);
        break;
      case "entry": {
        // The date in its own column, the text folded to what is left of the
        // width and hanging under itself rather than under the date.
        const width = pen.body - DATE_COLUMN;
        const pieces = fold(line.text, pen.sans, 9, width);
        pen.room(9 * pieces.length + 2);
        pieces.forEach((piece, i) => {
          pen.room(9);
          if (i === 0 && line.on) {
            pen.page.drawText(day(line.on), {
              x: pen.margin,
              y: pen.y - 9,
              size: 9,
              font: pen.sans,
            });
          }
          pen.page.drawText(printable(piece), {
            x: pen.margin + DATE_COLUMN,
            y: pen.y - 9,
            size: 9,
            font: pen.sans,
          });
          pen.gap(12.4);
        });
        break;
      }
      case "blank":
        pen.gap(8);
        break;
      default:
        pen.text(line.text, pen.sans, 9.5, 13.5);
    }
  }

  await pen.signature({
    certification:
      "I certify that this report is an accurate account of the services this agency provided to this client in the period it covers, taken from the agency's own record of that work.",
    signature,
  });

  return pen.finish();
}
