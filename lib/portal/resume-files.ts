import "server-only";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import { BorderStyle, Document, Packer, Paragraph, TextRun } from "docx";
import {
  bullets,
  datesText,
  realJobs,
  sectionOrder,
  SECTION_TITLE,
  type ResumeData,
} from "./resume";

/**
 * The resume as a PDF and as a Word file, from the saved draft alone.
 *
 * One plain layout, the kind an employer's system reads without trouble:
 * one column, real text, no tables, no images, standard fonts. The Word copy
 * is there so the client or a job coach can change a line later without
 * coming back to the portal.
 */

function contactLine(d: ResumeData): string {
  return [d.contact.city, d.contact.phone, d.contact.email].filter(Boolean).join("  |  ");
}

function jobHeading(j: { title: string; employer: string; city: string }): string {
  return [j.title, [j.employer, j.city].filter(Boolean).join(", ")].filter(Boolean).join(" — ");
}

// ── PDF ───────────────────────────────────────────────────────
const PAGE_W = 612;
const PAGE_H = 792;
const MARGIN = 54;
const INK = rgb(0.1, 0.1, 0.1);
const SOFT = rgb(0.35, 0.35, 0.35);

/** Standard fonts carry WinAnsi only; anything else is left out. */
function encodable(font: PDFFont, text: string): string {
  let out = "";
  for (const ch of text.replace(/[‘’]/g, "'").replace(/[“”]/g, '"')) {
    try {
      font.encodeText(ch);
      out += ch;
    } catch {
      // Dropped rather than shown as a question mark: an emoji or a symbol
      // the font cannot draw is never the substance of a line.
    }
  }
  return out;
}

function wrap(font: PDFFont, text: string, size: number, width: number): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  let current = "";
  for (const word of words) {
    const next = current ? `${current} ${word}` : word;
    if (font.widthOfTextAtSize(next, size) <= width) {
      current = next;
    } else {
      if (current) lines.push(current);
      // A single word wider than the line is cut rather than run off the page.
      let w = word;
      while (font.widthOfTextAtSize(w, size) > width && w.length > 1) {
        let cut = w.length - 1;
        while (cut > 1 && font.widthOfTextAtSize(w.slice(0, cut), size) > width) cut--;
        lines.push(w.slice(0, cut));
        w = w.slice(cut);
      }
      current = w;
    }
  }
  if (current) lines.push(current);
  return lines;
}

export async function buildResumePdf(d: ResumeData): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.setTitle(`${d.contact.name || "Resume"} - Resume`);
  pdf.setProducer("Zion Voc Rehab client portal");
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const width = PAGE_W - MARGIN * 2;

  let page: PDFPage = pdf.addPage([PAGE_W, PAGE_H]);
  let y = PAGE_H - MARGIN;

  const room = (needed: number) => {
    if (y - needed < MARGIN) {
      page = pdf.addPage([PAGE_W, PAGE_H]);
      y = PAGE_H - MARGIN;
    }
  };
  const text = (t: string, opts: { font?: PDFFont; size?: number; color?: ReturnType<typeof rgb>; indent?: number; gap?: number } = {}) => {
    const font = opts.font ?? regular;
    const size = opts.size ?? 10.5;
    const indent = opts.indent ?? 0;
    for (const l of wrap(font, encodable(font, t), size, width - indent)) {
      room(size + 3);
      page.drawText(l, { x: MARGIN + indent, y: y - size, size, font, color: opts.color ?? INK });
      y -= size + 3;
    }
    y -= opts.gap ?? 0;
  };
  const bullet = (t: string) => {
    const size = 10.5;
    const lines = wrap(regular, encodable(regular, t), size, width - 14);
    lines.forEach((l, i) => {
      room(size + 3);
      if (i === 0) page.drawText("•", { x: MARGIN + 3, y: y - size, size, font: regular, color: INK });
      page.drawText(l, { x: MARGIN + 14, y: y - size, size, font: regular, color: INK });
      y -= size + 3;
    });
  };
  const heading = (t: string) => {
    room(30);
    y -= 8;
    page.drawText(encodable(bold, t.toUpperCase()), { x: MARGIN, y: y - 11, size: 11, font: bold, color: INK });
    y -= 15;
    page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_W - MARGIN, y }, thickness: 0.75, color: SOFT });
    y -= 6;
  };

  text(d.contact.name || "Resume", { font: bold, size: 20, gap: 2 });
  const contact = contactLine(d);
  if (contact) text(contact, { size: 10, color: SOFT, gap: 4 });

  for (const kind of sectionOrder(d)) {
    heading(SECTION_TITLE[kind]);
    if (kind === "summary") text(d.summary);
    if (kind === "jobs") {
      for (const j of realJobs(d)) {
        room(30);
        text(jobHeading(j), { font: bold, size: 10.5 });
        const dates = datesText(j);
        if (dates) text(dates, { size: 9.5, color: SOFT });
        for (const b of bullets(j.duties)) bullet(b);
        y -= 6;
      }
    }
    if (kind === "skills") text(d.skills.join(", "));
    if (kind === "education") {
      for (const e of d.education.filter((x) => x.school || x.what)) {
        text([e.what, e.school].filter(Boolean).join(" — ") + (e.year ? `, ${e.year}` : ""));
      }
    }
    if (kind === "certs") {
      for (const c of d.certs.filter((x) => x.name)) bullet(c.name + (c.year ? `, ${c.year}` : ""));
    }
    if (kind === "volunteer") {
      for (const v of d.volunteer.filter((x) => x.org || x.role)) {
        text([v.role, v.org].filter(Boolean).join(" — "), { font: bold });
        for (const b of bullets(v.duties)) bullet(b);
        y -= 6;
      }
    }
  }

  return pdf.save();
}

// ── Word ──────────────────────────────────────────────────────
const FONT = "Calibri";

function run(t: string, opts: { bold?: boolean; size?: number; color?: string } = {}) {
  return new TextRun({ text: t, bold: opts.bold, size: opts.size ?? 21, color: opts.color, font: FONT });
}

export async function buildResumeDocx(d: ResumeData): Promise<Buffer> {
  const children: Paragraph[] = [];
  children.push(new Paragraph({ children: [run(d.contact.name || "Resume", { bold: true, size: 40 })] }));
  const contact = contactLine(d);
  if (contact) children.push(new Paragraph({ children: [run(contact, { size: 20, color: "555555" })], spacing: { after: 120 } }));

  const heading = (t: string) =>
    children.push(
      new Paragraph({
        children: [run(t.toUpperCase(), { bold: true, size: 22 })],
        spacing: { before: 240, after: 80 },
        border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: "888888", space: 2 } },
      }),
    );
  const para = (t: string, opts: { bold?: boolean; size?: number; color?: string; after?: number } = {}) =>
    children.push(new Paragraph({ children: [run(t, opts)], spacing: { after: opts.after ?? 40 } }));
  const bullet = (t: string) => children.push(new Paragraph({ children: [run(t)], bullet: { level: 0 } }));

  for (const kind of sectionOrder(d)) {
    heading(SECTION_TITLE[kind]);
    if (kind === "summary") para(d.summary);
    if (kind === "jobs") {
      for (const j of realJobs(d)) {
        para(jobHeading(j), { bold: true, after: 0 });
        const dates = datesText(j);
        if (dates) para(dates, { size: 19, color: "555555" });
        for (const b of bullets(j.duties)) bullet(b);
        children.push(new Paragraph({ children: [], spacing: { after: 60 } }));
      }
    }
    if (kind === "skills") para(d.skills.join(", "));
    if (kind === "education") {
      for (const e of d.education.filter((x) => x.school || x.what)) {
        para([e.what, e.school].filter(Boolean).join(" — ") + (e.year ? `, ${e.year}` : ""));
      }
    }
    if (kind === "certs") for (const c of d.certs.filter((x) => x.name)) bullet(c.name + (c.year ? `, ${c.year}` : ""));
    if (kind === "volunteer") {
      for (const v of d.volunteer.filter((x) => x.org || x.role)) {
        para([v.role, v.org].filter(Boolean).join(" — "), { bold: true, after: 0 });
        for (const b of bullets(v.duties)) bullet(b);
      }
    }
  }

  const doc = new Document({
    creator: "Zion Voc Rehab client portal",
    title: `${d.contact.name || "Resume"} - Resume`,
    styles: { default: { document: { run: { font: FONT, size: 21 } } } },
    sections: [
      {
        // US Letter, as an employer here will print it.
        properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1000, bottom: 1000, left: 1080, right: 1080 } } },
        children,
      },
    ],
  });
  return Packer.toBuffer(doc);
}
