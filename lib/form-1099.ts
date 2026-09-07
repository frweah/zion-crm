import "server-only";
import { createHash } from "node:crypto";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";

/**
 * Form 1099-NEC recipient statements and filing files.
 *
 * Copy B is drawn here rather than filled into the IRS PDF, which the other
 * forms in this system do. Two reasons. Copy A is the only part the IRS
 * scans, it must be the red-ink original or an electronic filing, and we file
 * electronically — so the official PDF gets us nothing for Copy A. And the
 * recipient statement is expressly allowed to be a substitute under IRS
 * Publication 1179, which sets out what it must contain rather than what it
 * must look like.
 *
 * That permission is not a licence to improvise. Everything Pub 1179 requires
 * of a substitute statement is here: the box numbers and captions in the
 * official order, the payer and recipient blocks, the OMB number, the notice
 * that the information is being furnished to the IRS, and the instructions for
 * the recipient. A substitute statement should still be looked at by the
 * practice's CPA before the first one is sent.
 *
 * The recipient's taxpayer number is truncated to its last four digits, which
 * payee statements are permitted to do and which means this file never needs
 * the number in the clear. The payer's own EIN is printed in full, as it must
 * be.
 */

export type Recipient1099 = {
  id: string;
  legalName: string;
  businessName: string;
  addressSnapshot: string;
  tinType: string | null;
  tinLast4: string | null;
  nonemployeeComp: number;
  corrected?: boolean;
};

export type Payer1099 = {
  name: string;
  address: string;
  phone: string;
  ein: string;
  /** Utah withholding account number, when the state copy is in play. */
  stateNumber?: string;
};

export type Filled1099 = { bytes: Uint8Array; sha256: string };

const usd = (n: number) =>
  n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** 12-3456789, the way an EIN is written. */
function formatEin(ein: string): string {
  const d = ein.replace(/\D/g, "");
  return d.length === 9 ? `${d.slice(0, 2)}-${d.slice(2)}` : ein;
}

/** A truncated taxpayer number, which is what a payee statement may show. */
function truncatedTin(type: string | null, last4: string | null): string {
  if (!last4) return "";
  return type === "EIN" ? `XX-XXX${last4}` : `XXX-XX-${last4}`;
}

const PAGE_W = 612;
const PAGE_H = 792;
const MARGIN = 40;

type Ctx = { page: PDFPage; font: PDFFont; bold: PDFFont };

function box(
  ctx: Ctx,
  x: number,
  y: number,
  w: number,
  h: number,
  caption: string,
  value: string,
  opts: { valueSize?: number; captionSize?: number } = {},
) {
  ctx.page.drawRectangle({
    x,
    y,
    width: w,
    height: h,
    borderColor: rgb(0, 0, 0),
    borderWidth: 0.7,
  });
  ctx.page.drawText(caption, {
    x: x + 4,
    y: y + h - 10,
    size: opts.captionSize ?? 6.5,
    font: ctx.font,
  });
  if (value) {
    for (const [i, line] of value.split("\n").entries()) {
      ctx.page.drawText(line, {
        x: x + 6,
        y: y + h - 24 - i * 11,
        size: opts.valueSize ?? 9,
        font: ctx.bold,
      });
    }
  }
}

/**
 * One recipient's Copy B, as a single-page statement with the instructions on
 * the back — the same arrangement as the official form.
 */
export async function buildCopyB(
  year: number,
  payer: Payer1099,
  r: Recipient1099,
): Promise<Filled1099> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  const page = doc.addPage([PAGE_W, PAGE_H]);
  const ctx: Ctx = { page, font, bold };
  const W = PAGE_W - MARGIN * 2;
  let y = PAGE_H - MARGIN;

  // ── heading ───────────────────────────────────────────────
  page.drawText(`Form 1099-NEC`, { x: MARGIN, y: y - 16, size: 15, font: bold });
  page.drawText(`Nonemployee Compensation`, { x: MARGIN, y: y - 30, size: 10, font });
  page.drawText(`${year}`, { x: MARGIN + 250, y: y - 20, size: 18, font: bold });
  page.drawText("OMB No. 1545-0116", { x: PAGE_W - MARGIN - 110, y: y - 10, size: 7, font });
  page.drawText("Copy B — For Recipient", {
    x: PAGE_W - MARGIN - 110,
    y: y - 22,
    size: 8,
    font: bold,
  });
  if (r.corrected) {
    page.drawText("CORRECTED", {
      x: PAGE_W - MARGIN - 110,
      y: y - 34,
      size: 9,
      font: bold,
      color: rgb(0.6, 0, 0),
    });
  }

  y -= 46;

  // ── payer and recipient ───────────────────────────────────
  const leftW = W * 0.55;
  const rightX = MARGIN + leftW + 8;
  const rightW = W - leftW - 8;

  const payerBlock = [payer.name, ...payer.address.split("\n"), payer.phone]
    .filter(Boolean)
    .join("\n");

  box(
    ctx,
    MARGIN,
    y - 74,
    leftW,
    74,
    "PAYER'S name, street address, city or town, state, ZIP code, and telephone no.",
    payerBlock,
    { valueSize: 8 },
  );
  box(ctx, rightX, y - 36, rightW, 36, "1  Nonemployee compensation", `$ ${usd(r.nonemployeeComp)}`, {
    valueSize: 12,
  });
  box(ctx, rightX, y - 74, rightW, 36, "4  Federal income tax withheld", "$ 0.00");
  y -= 82;

  box(ctx, MARGIN, y - 30, leftW, 30, "PAYER'S TIN", formatEin(payer.ein));
  box(
    ctx,
    rightX,
    y - 30,
    rightW,
    30,
    "RECIPIENT'S TIN",
    truncatedTin(r.tinType, r.tinLast4),
  );
  y -= 38;

  const recipientBlock = [
    r.legalName,
    r.businessName && r.businessName !== r.legalName ? r.businessName : "",
    ...r.addressSnapshot.split(", "),
  ]
    .filter(Boolean)
    .join("\n");

  box(ctx, MARGIN, y - 74, leftW, 74, "RECIPIENT'S name and address", recipientBlock, {
    valueSize: 8,
  });
  box(
    ctx,
    rightX,
    y - 36,
    rightW,
    36,
    "2  Payer made direct sales totaling $5,000 or more of consumer products to recipient for resale",
    "No",
    { captionSize: 5.5 },
  );
  box(ctx, rightX, y - 74, rightW, 36, "3  (Reserved for future use)", "");
  y -= 82;

  // ── state boxes ───────────────────────────────────────────
  const third = W / 3;
  box(ctx, MARGIN, y - 34, third - 4, 34, "5  State tax withheld", "$ 0.00");
  box(
    ctx,
    MARGIN + third,
    y - 34,
    third - 4,
    34,
    "6  State/Payer's state no.",
    payer.stateNumber ? `UT / ${payer.stateNumber}` : "",
  );
  box(ctx, MARGIN + third * 2, y - 34, third, 34, "7  State income", `$ ${usd(r.nonemployeeComp)}`);
  y -= 46;

  // ── the notice, which is required wording ─────────────────
  const notice =
    "This is important tax information and is being furnished to the IRS. If you are required to " +
    "file a return, a negligence penalty or other sanction may be imposed on you if this income " +
    "is taxable and the IRS determines that it has not been reported.";
  y = wrap(ctx, notice, MARGIN, y, W, 8, 11);

  y -= 8;
  page.drawLine({
    start: { x: MARGIN, y },
    end: { x: PAGE_W - MARGIN, y },
    thickness: 0.7,
  });
  y -= 14;

  page.drawText("Instructions for Recipient", { x: MARGIN, y, size: 9, font: bold });
  y -= 12;

  for (const para of RECIPIENT_INSTRUCTIONS) {
    y = wrap(ctx, para, MARGIN, y, W, 7.5, 10);
    y -= 4;
  }

  page.drawText(
    `Substitute Form 1099-NEC furnished by ${payer.name} under IRS Publication 1179.`,
    { x: MARGIN, y: MARGIN - 12, size: 6.5, font },
  );

  const bytes = await doc.save();
  return { bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
}

/** Draws wrapped text and returns the y it finished at. */
function wrap(
  ctx: Ctx,
  text: string,
  x: number,
  y: number,
  width: number,
  size: number,
  leading: number,
): number {
  const words = text.split(" ");
  let line = "";
  let cursor = y;

  for (const word of words) {
    const next = line ? `${line} ${word}` : word;
    if (ctx.font.widthOfTextAtSize(next, size) > width) {
      ctx.page.drawText(line, { x, y: cursor, size, font: ctx.font });
      cursor -= leading;
      line = word;
    } else {
      line = next;
    }
  }
  if (line) {
    ctx.page.drawText(line, { x, y: cursor, size, font: ctx.font });
    cursor -= leading;
  }
  return cursor;
}

/**
 * The recipient instructions, which a substitute statement has to carry.
 *
 * Condensed from the IRS instructions for Form 1099-NEC. They are reproduced
 * because a statement without them is not a compliant substitute, not because
 * anybody enjoys reading them.
 */
const RECIPIENT_INSTRUCTIONS = [
  "You received this form because a business paid you for services and you are not its employee. " +
    "If you are a sole proprietor or a member of a partnership and this payment is business income, " +
    "report it on Schedule C (Form 1040). You may owe self-employment tax on it, which Schedule SE " +
    "computes.",
  "Recipient's taxpayer identification number. For your protection, this form may show only the " +
    "last four digits of your social security number, individual taxpayer identification number, " +
    "adoption taxpayer identification number, or employer identification number. The payer has " +
    "reported your complete identification number to the IRS.",
  "Account number. May show an account or other unique number the payer assigned to distinguish " +
    "your account.",
  "Box 1. Shows nonemployee compensation. If the payer did not treat you as an employee and you " +
    "believe they should have, report this amount on the line for wages on your return and see " +
    "Form 8919 for how to figure the social security and Medicare tax you owe.",
  "Box 2. If checked, consumer products totaling $5,000 or more were sold to you for resale, on " +
    "buy-sell, deposit-commission, or other basis. Report any income from your sale of these " +
    "products on Schedule C (Form 1040).",
  "Box 4. Shows backup withholding. Generally, a payer must backup withhold if you did not furnish " +
    "your taxpayer identification number. Include this amount on your income tax return as tax " +
    "withheld.",
  "Boxes 5 to 7. Show state or local income tax withheld from the payments, the payer's state " +
    "identification number, and the amount of state income.",
  "If you believe any figure on this statement is wrong, contact the payer at the address and " +
    "telephone number shown above. If it cannot be resolved, you may contact the IRS. Keep this " +
    "statement with your tax records.",
];

// ─────────────────────────────────────────────────────────────
// Filing files
// ─────────────────────────────────────────────────────────────

/** One recipient with the number in the clear, for a filing file only. */
export type FilingRow = Recipient1099 & { tin: string };

function csvCell(value: string | number): string {
  const s = String(value ?? "");
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function csv(header: string[], rows: (string | number)[][]): string {
  return [header, ...rows].map((r) => r.map(csvCell).join(",")).join("\r\n") + "\r\n";
}

/** Splits "1 Street, Apt 2, Salt Lake City, UT, 84115" back into parts. */
function splitAddress(snapshot: string): {
  street: string;
  city: string;
  state: string;
  postal: string;
} {
  const parts = snapshot.split(",").map((p) => p.trim()).filter(Boolean);
  const postal = parts.length > 0 ? parts[parts.length - 1] : "";
  const state = parts.length > 1 ? parts[parts.length - 2] : "";
  const city = parts.length > 2 ? parts[parts.length - 3] : "";
  const street = parts.slice(0, Math.max(0, parts.length - 3)).join(", ");
  return { street, city, state, postal };
}

/**
 * Everything about the run in one flat file.
 *
 * This is the one to hand a CPA or a filing service: it says what it holds in
 * plain column names and makes no assumptions about whose template it is going
 * into.
 */
export function buildGenericCsv(year: number, payer: Payer1099, rows: FilingRow[]): string {
  return csv(
    [
      "tax_year",
      "payer_name",
      "payer_ein",
      "recipient_legal_name",
      "recipient_business_name",
      "recipient_tin",
      "recipient_tin_type",
      "recipient_street",
      "recipient_city",
      "recipient_state",
      "recipient_postal_code",
      "box_1_nonemployee_compensation",
      "box_4_federal_income_tax_withheld",
      "box_5_state_tax_withheld",
      "box_6_state",
      "box_7_state_income",
      "corrected",
    ],
    rows.map((r) => {
      const a = splitAddress(r.addressSnapshot);
      return [
        year,
        payer.name,
        formatEin(payer.ein),
        r.legalName,
        r.businessName,
        r.tin,
        r.tinType ?? "",
        a.street,
        a.city,
        a.state,
        a.postal,
        r.nonemployeeComp.toFixed(2),
        "0.00",
        "0.00",
        a.state === "UT" ? "UT" : "",
        r.nonemployeeComp.toFixed(2),
        r.corrected ? "1" : "0",
      ];
    }),
  );
}

/**
 * The same data under the field names the IRIS portal uses.
 *
 * IRIS accepts a CSV built from a template the IRS publishes per form type,
 * and that template is revised. The columns below are the 1099-NEC fields as
 * understood when this was written; they carry everything a filing needs, but
 * the header row has to be checked against the current IRS template before the
 * first upload, and corrected here if the IRS has moved on. Nothing in the file
 * itself would tell you it was stale.
 *
 * The screen that offers this download says the same thing, so nobody uploads
 * it in January assuming it was verified.
 */
export function buildIrisCsv(year: number, payer: Payer1099, rows: FilingRow[]): string {
  return csv(
    [
      "Tax Year",
      "Payer TIN",
      "Payer Name",
      "Payer Address Line 1",
      "Payer City",
      "Payer State",
      "Payer Zip Code",
      "Payer Phone Number",
      "Recipient TIN",
      "Recipient TIN Type",
      "Recipient Name",
      "Recipient Second Name Line",
      "Recipient Address Line 1",
      "Recipient City",
      "Recipient State",
      "Recipient Zip Code",
      "Account Number",
      "Corrected",
      "Nonemployee Compensation",
      "Federal Income Tax Withheld",
      "Direct Sales Indicator",
      "State Tax Withheld 1",
      "State 1",
      "State Income 1",
    ],
    rows.map((r) => {
      const a = splitAddress(r.addressSnapshot);
      const p = splitAddress(payer.address.replace(/\n/g, ", "));
      return [
        year,
        formatEin(payer.ein),
        payer.name,
        p.street,
        p.city,
        p.state,
        p.postal,
        payer.phone,
        r.tin,
        r.tinType === "EIN" ? "EIN" : "SSN",
        r.legalName,
        r.businessName,
        a.street,
        a.city,
        a.state,
        a.postal,
        "",
        r.corrected ? "1" : "0",
        r.nonemployeeComp.toFixed(2),
        "0.00",
        "0",
        "0.00",
        a.state === "UT" ? "UT" : "",
        r.nonemployeeComp.toFixed(2),
      ];
    }),
  );
}
