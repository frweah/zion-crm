import "server-only";
import { createHash } from "node:crypto";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";

/**
 * A staff policy as signed, on paper-sized pages: the text word for word, then
 * who signed, when, from where, and the hash of the text they were shown - so
 * the copy on their file says exactly what they agreed to, and can be matched
 * against the version stored in the database.
 */
export type PolicyBlock = { type: string; text: string };

export type SignedPolicy = { bytes: Uint8Array; sha256: string };

const PAGE = { width: 612, height: 792 };
const MARGIN = 64;
const WIDTH = PAGE.width - MARGIN * 2;

/** WinAnsi cannot draw every character a policy might hold; the few it cannot are swapped for plain ones. */
function printable(text: string): string {
  return text
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, "-")
    .replace(/…/g, "...")
    .replace(/[^\x20-\x7E\xA0-\xFF]/g, "");
}

function wrap(text: string, font: PDFFont, size: number, width: number): string[] {
  const lines: string[] = [];
  let line = "";
  for (const word of printable(text).split(/\s+/).filter(Boolean)) {
    const next = line ? `${line} ${word}` : word;
    if (font.widthOfTextAtSize(next, size) > width && line) {
      lines.push(line);
      line = word;
    } else {
      line = next;
    }
  }
  if (line) lines.push(line);
  return lines;
}

export async function signedPolicyPdf({
  title,
  version,
  blocks,
  textSha256,
  signerName,
  signedAt,
  ip,
  staffName,
  role,
}: {
  title: string;
  version: number;
  blocks: PolicyBlock[];
  textSha256: string;
  signerName: string;
  signedAt: Date;
  ip: string;
  staffName: string;
  role: string;
}): Promise<SignedPolicy> {
  const doc = await PDFDocument.create();
  doc.setTitle(`${title} - signed by ${signerName}`);
  const regular = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  let page: PDFPage = doc.addPage([PAGE.width, PAGE.height]);
  let y = PAGE.height - MARGIN;

  const draw = (text: string, font: PDFFont, size: number, indent = 0, gapAfter = 4) => {
    for (const line of wrap(text, font, size, WIDTH - indent)) {
      if (y - size < MARGIN) {
        page = doc.addPage([PAGE.width, PAGE.height]);
        y = PAGE.height - MARGIN;
      }
      page.drawText(line, { x: MARGIN + indent, y: y - size, size, font, color: rgb(0.1, 0.1, 0.1) });
      y -= size * 1.35;
    }
    y -= gapAfter;
  };

  draw(title, bold, 18, 0, 10);
  let item = 0;
  for (const b of blocks) {
    if (b.type === "h2") {
      item = 0;
      draw(b.text, bold, 12.5, 0, 4);
    } else if (b.type === "li") {
      item += 1;
      draw(`${item}.  ${b.text}`, regular, 10.5, 12, 5);
    } else {
      draw(b.text, b.type === "strong" ? bold : regular, 10.5, 0, 7);
    }
  }

  y -= 10;
  draw("Signed electronically", bold, 12.5, 0, 6);
  const stamp = signedAt.toLocaleString("en-US", { timeZone: "America/Denver", dateStyle: "long", timeStyle: "short" });
  for (const line of [
    `Signature: ${signerName}`,
    `Name on the CRM: ${staffName}`,
    `Role: ${role}`,
    `Signed: ${stamp} (Mountain time)`,
    `From: ${ip || "address not recorded"}`,
    `Policy: ${title}, version ${version}`,
    `SHA-256 of the policy text shown: ${textSha256}`,
  ]) {
    draw(line, regular, 10, 0, 2);
  }

  const bytes = await doc.save();
  return { bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
}
