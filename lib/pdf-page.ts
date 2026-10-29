import "server-only";
import { createHash } from "node:crypto";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import { ORG } from "@/lib/roles";

/**
 * Laying words on a page, and signing the page.
 *
 * Two documents leave this building with the practice's name under them: a
 * completed USOR form on its way to the billing office, and a monthly report
 * on its way to a counselor. Both are signed, and the signature is the same
 * act — so it is written once, here, rather than twice.
 *
 * That is not tidiness. The block below is the attestation: the sentence the
 * signer is certifying, their name, the vendor number, and the moment the
 * database recorded them signing. Two copies of it would be two things the
 * practice says it is certifying, and the day they drifted apart nobody would
 * be able to say which one the counselor received.
 *
 * `Pen` is the rest of it — margins, folding, and starting a new page when
 * the current one runs out. The folding matters more than it looks: the forms
 * lay their tables out with spaces in a monospaced face, so a line that wraps
 * at the wrong width pulls the columns apart, and the report's dated lines
 * need the date to stay in its own column when the text behind it wraps.
 */

export const LETTER = { width: 612, height: 792 } as const;
export const MARGIN = 54;
export const BODY = LETTER.width - MARGIN * 2;

/** The ink. Near-black rather than black, which prints softer. */
const INK = rgb(0.1, 0.1, 0.1);
const QUIET = rgb(0.25, 0.24, 0.22);
const HAIRLINE = rgb(0.7, 0.68, 0.64);
const RULE = rgb(0.55, 0.53, 0.5);

/**
 * WinAnsi cannot draw everything a record might hold.
 *
 * The few characters it cannot become plain ones rather than throwing: a name
 * with a curly apostrophe in it is not a reason a form cannot be billed. Em
 * dashes are everywhere in this practice's own writing, so they are first.
 */
export function printable(text: string): string {
  return text
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, "-")
    .replace(/…/g, "...")
    .replace(/[^\x20-\x7E\xA0-\xFF]/g, "");
}

/** Long lines fold rather than run off the page, keeping their indent. */
export function fold(line: string, font: PDFFont, size: number, width: number): string[] {
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

/**
 * Is this actually the image it says it is?
 *
 * Checked before pdf-lib is handed it, because pdf-lib does not reliably
 * reject what it cannot read - on a malformed PNG its embed simply never
 * settles. The first bytes of a PNG and of a JPEG are fixed, so the cheap
 * check catches the common case before the expensive one can hang.
 */
export function looksLikeImage(image: { bytes: Uint8Array; type: "png" | "jpg" }): boolean {
  const b = image.bytes;
  if (image.type === "png") {
    return (
      b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
      b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a
    );
  }
  return b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
}

/**
 * Who signed it.
 *
 * `at` is null for a draft, and the block says so in place of a date rather
 * than leaving the line out: a page with a signature line and no date on it
 * reads as signed.
 */
export type Signature = {
  name: string;
  at: Date | null;
  /** Their uploaded signature, if they have one. PNG or JPEG. */
  image?: { bytes: Uint8Array; type: "png" | "jpg" } | null;
};

export type Finished = { bytes: Uint8Array; sha256: string };

export class Pen {
  readonly doc: PDFDocument;
  readonly width: number;
  readonly height: number;
  readonly margin: number;
  readonly body: number;
  page: PDFPage;
  y: number;

  /** The four faces anything here draws with, embedded once. */
  mono!: PDFFont;
  monoBold!: PDFFont;
  sans!: PDFFont;
  sansBold!: PDFFont;

  private constructor(doc: PDFDocument, size: { width: number; height: number }, margin: number) {
    this.doc = doc;
    this.width = size.width;
    this.height = size.height;
    this.margin = margin;
    this.body = size.width - margin * 2;
    this.page = doc.addPage([size.width, size.height]);
    this.y = size.height - margin;
  }

  static async open(
    title: string,
    size: { width: number; height: number } = LETTER,
    margin = MARGIN,
  ): Promise<Pen> {
    const doc = await PDFDocument.create();
    doc.setTitle(title);
    doc.setProducer(ORG.name);
    const pen = new Pen(doc, size, margin);
    pen.mono = await doc.embedFont(StandardFonts.Courier);
    pen.monoBold = await doc.embedFont(StandardFonts.CourierBold);
    pen.sans = await doc.embedFont(StandardFonts.Helvetica);
    pen.sansBold = await doc.embedFont(StandardFonts.HelveticaBold);
    return pen;
  }

  /** A new page when there is not this much left on the current one. */
  room(need: number): void {
    if (this.y - need < this.margin) {
      this.page = this.doc.addPage([this.width, this.height]);
      this.y = this.height - this.margin;
    }
  }

  /** One line of text, folded to the width, at the pen. */
  text(line: string, font: PDFFont, size = 8.6, lead = size * 1.32, colour = INK): void {
    for (const piece of fold(line, font, size, this.body)) {
      this.room(size);
      this.page.drawText(piece, { x: this.margin, y: this.y - size, size, font, color: colour });
      this.y -= lead;
    }
  }

  gap(points: number): void {
    this.y -= points;
  }

  /** A rule across the page, or a shorter one where a signature goes. */
  rule(width = this.body, colour = HAIRLINE, thickness = 0.7): void {
    this.room(thickness + 2);
    this.page.drawLine({
      start: { x: this.margin, y: this.y },
      end: { x: this.margin + width, y: this.y },
      thickness,
      color: colour,
    });
  }

  /**
   * The signature block, and the only one.
   *
   * `certification` is what the signer is saying is true, and it differs: a
   * USOR form certifies the information on the form, a monthly report
   * certifies the account of the services. Everything else - the heading, the
   * image, the name, the vendor number, the timestamp in Mountain time, and
   * the word DRAFT where there is no timestamp - is the same in both because
   * it is the same signature.
   */
  async signature(opts: { certification: string; signature: Signature }): Promise<void> {
    const { certification, signature } = opts;

    this.gap(10);
    this.room(96);
    this.rule();
    this.gap(16);

    this.room(11);
    this.page.drawText("Signed electronically", {
      x: this.margin,
      y: this.y - 11,
      size: 11,
      font: this.sansBold,
      color: INK,
    });
    this.gap(22);

    for (const line of fold(certification, this.sans, 9, this.body)) {
      this.room(9);
      this.page.drawText(line, { x: this.margin, y: this.y - 9, size: 9, font: this.sans, color: QUIET });
      this.gap(12);
    }
    this.gap(8);

    if (signature.image && looksLikeImage(signature.image)) {
      try {
        // Raced against a timeout: pdf-lib's embed returns a promise that
        // never settles on some malformed images rather than rejecting, and a
        // signed document that hangs on its way out of the building is worse
        // than one that goes without the picture of a signature on it.
        const drawn = await Promise.race([
          signature.image.type === "png"
            ? this.doc.embedPng(signature.image.bytes)
            : this.doc.embedJpg(signature.image.bytes),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error("the signature image could not be read")), 4000).unref?.(),
          ),
        ]);
        // Sized to a signature line, never blown up past what was uploaded.
        const height = Math.min(40, drawn.height);
        const width = (drawn.width / drawn.height) * height;
        this.room(height + 6);
        this.page.drawImage(drawn, {
          x: this.margin,
          y: this.y - height,
          width: Math.min(width, 220),
          height,
        });
        this.gap(height + 6);
      } catch {
        // An image that will not embed is not a reason to lose the document:
        // the typed name and the timestamp below are what the signature is.
      }
    }

    this.rule(240, RULE);
    this.gap(14);

    const stamp = signature.at
      ? signature.at.toLocaleString("en-US", {
          timeZone: "America/Denver",
          dateStyle: "long",
          timeStyle: "short",
        })
      : null;
    for (const line of [
      `CRP signature: /s/ ${signature.name}`,
      `${ORG.name}   Vendor #${ORG.vendor}`,
      stamp ? `Signed ${stamp} (Mountain time)` : "DRAFT - not signed",
    ]) {
      this.room(9.5);
      this.page.drawText(printable(line), {
        x: this.margin,
        y: this.y - 9.5,
        size: 9.5,
        font: this.sans,
        color: INK,
      });
      this.gap(13);
    }
  }

  async finish(): Promise<Finished> {
    const bytes = await this.doc.save();
    return { bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
  }
}
