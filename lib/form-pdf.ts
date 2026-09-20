import "server-only";
import { createHash } from "node:crypto";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import { formToText, type FormContext } from "@/lib/form-text";
import { templateById } from "@/lib/form-templates";
import { ORG } from "@/lib/roles";

/**
 * A completed USOR form as a PDF, to attach to the billing email.
 *
 * The content is not rendered again here: it is `formToText`, the one
 * renderer, laid out on pages. A second renderer would drift from the first,
 * and the copy USOR receives would stop matching the copy the CRM shows -
 * which is the one kind of disagreement a billing document cannot have.
 *
 * Courier throughout the body, because formToText lays its tables out with
 * spaces and a proportional face would pull the columns apart.
 *
 * The signature block is the PDF's own: the person's uploaded signature drawn
 * as an image where one exists, their typed name beside it either way, and
 * the moment they signed. The image is a convenience, not the signature - the
 * signature is the completion recorded against their name in the database,
 * which is what the timestamp comes from.
 */
export type SignedForm = { bytes: Uint8Array; sha256: string };

const PAGE = { width: 612, height: 792 };
const MARGIN = 54;
const WIDTH = PAGE.width - MARGIN * 2;
const SIZE = 8.6;
const LINE = SIZE * 1.32;

/**
 * Is this actually the image it says it is?
 *
 * Checked before pdf-lib is handed it, because pdf-lib does not reliably
 * reject what it cannot read - on a malformed PNG its embed simply never
 * settles. The first bytes of a PNG and of a JPEG are fixed, so the cheap
 * check catches the common case before the expensive one can hang.
 */
function looksLikeImage(image: { bytes: Uint8Array; type: "png" | "jpg" }): boolean {
  const b = image.bytes;
  if (image.type === "png") {
    return (
      b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
      b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a
    );
  }
  return b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
}

/** WinAnsi cannot draw everything a form might hold; the few it cannot become plain ones. */
function printable(text: string): string {
  return text
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, "-")
    .replace(/…/g, "...")
    .replace(/[^\x20-\x7E\xA0-\xFF]/g, "");
}

/** Long lines fold rather than run off the page, keeping their indent. */
function fold(line: string, font: PDFFont, size: number, width: number): string[] {
  const text = printable(line);
  if (font.widthOfTextAtSize(text, size) <= width) return [text];
  const indent = (text.match(/^\s*/)?.[0] ?? "").length;
  const pad = " ".repeat(Math.min(indent + 2, 20));
  const out: string[] = [];
  let current = "";
  for (const word of text.trimStart().split(" ")) {
    const next = current ? `${current} ${word}` : word;
    if (font.widthOfTextAtSize((out.length ? pad : "") + next, size) > width && current) {
      out.push((out.length ? pad : "") + current);
      current = word;
    } else {
      current = next;
    }
  }
  if (current) out.push((out.length ? pad : "") + current);
  return out;
}

export async function signedFormPdf({
  templateId,
  data,
  ctx,
  signature,
}: {
  templateId: string;
  data: Record<string, unknown>;
  ctx: FormContext;
  signature: {
    name: string;
    at: Date | null;
    /** Their uploaded signature, if they have one. PNG or JPEG. */
    image?: { bytes: Uint8Array; type: "png" | "jpg" } | null;
  };
}): Promise<SignedForm> {
  const tpl = templateById(templateId);
  const doc = await PDFDocument.create();
  doc.setTitle(`${tpl?.usor ?? "USOR form"} - ${ctx.clientName}`);
  doc.setProducer(ORG.name);
  const mono = await doc.embedFont(StandardFonts.Courier);
  const monoBold = await doc.embedFont(StandardFonts.CourierBold);
  const sans = await doc.embedFont(StandardFonts.Helvetica);
  const sansBold = await doc.embedFont(StandardFonts.HelveticaBold);

  let page: PDFPage = doc.addPage([PAGE.width, PAGE.height]);
  let y = PAGE.height - MARGIN;

  const room = (need: number) => {
    if (y - need < MARGIN) {
      page = doc.addPage([PAGE.width, PAGE.height]);
      y = PAGE.height - MARGIN;
    }
  };

  const write = (line: string, font: PDFFont, size = SIZE) => {
    for (const piece of fold(line, font, size, WIDTH)) {
      room(size);
      page.drawText(piece, { x: MARGIN, y: y - size, size, font, color: rgb(0.1, 0.1, 0.1) });
      y -= LINE;
    }
  };

  // The body, exactly as the CRM and the email show it, minus the text
  // signature line - the block below says the same thing with more in it.
  const lines = formToText(templateId, data, ctx, { omitSignature: true }).split("\n");
  lines.forEach((line, i) => write(line, i < 2 ? monoBold : mono));

  // ── who signed it ──────────────────────────────────────────
  y -= 10;
  room(96);
  page.drawLine({
    start: { x: MARGIN, y },
    end: { x: PAGE.width - MARGIN, y },
    thickness: 0.7,
    color: rgb(0.7, 0.68, 0.64),
  });
  y -= 16;

  page.drawText("Signed electronically", { x: MARGIN, y: y - 11, size: 11, font: sansBold, color: rgb(0.1, 0.1, 0.1) });
  y -= 22;

  for (const line of fold(
    "I understand that I am electronically signing this form, and I certify that the information on it is correct to the best of my knowledge.",
    sans,
    9,
    WIDTH,
  )) {
    room(9);
    page.drawText(line, { x: MARGIN, y: y - 9, size: 9, font: sans, color: rgb(0.25, 0.24, 0.22) });
    y -= 12;
  }
  y -= 8;

  if (signature.image && looksLikeImage(signature.image)) {
    try {
      // Raced against a timeout: pdf-lib's embed returns a promise that never
      // settles on some malformed images rather than rejecting, and a signed
      // form that hangs on the way to the billing office is worse than one
      // that goes without the picture of a signature on it.
      const drawn = await Promise.race([
        signature.image.type === "png"
          ? doc.embedPng(signature.image.bytes)
          : doc.embedJpg(signature.image.bytes),
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error("the signature image could not be read")), 4000).unref?.(),
        ),
      ]);
      // Sized to a signature line, never blown up past what was uploaded.
      const height = Math.min(40, drawn.height);
      const width = (drawn.width / drawn.height) * height;
      room(height + 6);
      page.drawImage(drawn, { x: MARGIN, y: y - height, width: Math.min(width, 220), height });
      y -= height + 6;
    } catch {
      // An image that will not embed is not a reason to lose the form: the
      // typed name and the timestamp below are what the signature is.
    }
  }

  page.drawLine({
    start: { x: MARGIN, y },
    end: { x: MARGIN + 240, y },
    thickness: 0.7,
    color: rgb(0.55, 0.53, 0.5),
  });
  y -= 14;

  const stamp = signature.at
    ? signature.at.toLocaleString("en-US", { timeZone: "America/Denver", dateStyle: "long", timeStyle: "short" })
    : null;
  for (const line of [
    `CRP signature: /s/ ${signature.name}`,
    `${ORG.name}   Vendor #${ORG.vendor}`,
    stamp ? `Signed ${stamp} (Mountain time)` : "DRAFT - not signed",
  ]) {
    room(9.5);
    page.drawText(printable(line), { x: MARGIN, y: y - 9.5, size: 9.5, font: sans, color: rgb(0.1, 0.1, 0.1) });
    y -= 13;
  }

  const bytes = await doc.save();
  return { bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
}
