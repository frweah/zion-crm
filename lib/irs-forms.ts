import "server-only";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import { PDFDocument, StandardFonts } from "pdf-lib";
import { W9_CLASSIFICATIONS, type W9Classification } from "@/lib/irs-forms-shared";

/**
 * Filling the official IRS PDFs.
 *
 * These are XFA forms. pdf-lib strips the XFA layer and writes the AcroForm
 * fields underneath, which is what viewers then render. The fields carry no
 * descriptions of their own, so the mapping below was established by comparing
 * each field's position on the page against the published form layout, and
 * then confirmed against a labelled sample — every box filled with the name of
 * the line it should be, and checked by eye.
 *
 * If a form is ever revised, regenerate that sample and check it again before
 * anyone signs. Field names like f_1 and f_9 carry no meaning that would warn
 * you the IRS moved them.
 */

const FORM_DIR = path.join(process.cwd(), "assets", "irs-forms");

export type W8BenData = {
  name: string;
  citizenshipCountry: string;
  residenceStreet: string;
  residenceCity: string;
  residenceCountry: string;
  mailingStreet?: string;
  mailingCity?: string;
  mailingCountry?: string;
  usTin?: string;
  foreignTin?: string;
  ftinNotRequired?: boolean;
  reference?: string;
  dateOfBirth?: string;
  treatyCountry?: string;
  signerName: string;
  signedOn: string;
  signingForAnother?: boolean;
};

/** Confirmed against the labelled sample. Page 1 of Form W-8BEN. */
const W8BEN_FIELDS = {
  name: "f_1[0]",
  citizenshipCountry: "f_2[0]",
  residenceStreet: "f_3[0]",
  residenceCity: "f_4[0]",
  residenceCountry: "f_5[0]",
  mailingStreet: "f_6[0]",
  mailingCity: "f_7[0]",
  mailingCountry: "f_8[0]",
  usTin: "f_9[0]",
  foreignTin: "f_10[0]",
  reference: "f_11[0]",
  dateOfBirth: "f_12[0]",
  treatyCountry: "f_13[0]",
  signDate: "Date[0]",
  printName: "f_21[0]",
} as const;

const W8BEN_PREFIX = "topmostSubform[0].Page1[0].";

export type FilledForm = { bytes: Uint8Array; sha256: string };

export async function fillW8BEN(data: W8BenData): Promise<FilledForm> {
  const source = await readFile(path.join(FORM_DIR, "fw8ben.pdf"));
  const doc = await PDFDocument.load(source, { ignoreEncryption: true });
  const form = doc.getForm();
  const helvetica = await doc.embedFont(StandardFonts.Helvetica);

  const set = (field: string, value: string | undefined) => {
    if (!value) return;
    const f = form.getTextField(W8BEN_PREFIX + field);
    const max = f.getMaxLength();
    // Truncation here would be silent data loss on a tax form, so the caller
    // validates against these caps first; this is the last line of defence.
    f.setText(max ? value.slice(0, max) : value);
    f.updateAppearances(helvetica);
    f.enableReadOnly();
  };

  set(W8BEN_FIELDS.name, data.name);
  set(W8BEN_FIELDS.citizenshipCountry, data.citizenshipCountry);
  set(W8BEN_FIELDS.residenceStreet, data.residenceStreet);
  set(W8BEN_FIELDS.residenceCity, data.residenceCity);
  set(W8BEN_FIELDS.residenceCountry, data.residenceCountry);
  set(W8BEN_FIELDS.mailingStreet, data.mailingStreet);
  set(W8BEN_FIELDS.mailingCity, data.mailingCity);
  set(W8BEN_FIELDS.mailingCountry, data.mailingCountry);
  set(W8BEN_FIELDS.usTin, data.usTin);
  set(W8BEN_FIELDS.foreignTin, data.foreignTin);
  set(W8BEN_FIELDS.reference, data.reference);
  set(W8BEN_FIELDS.dateOfBirth, data.dateOfBirth);
  set(W8BEN_FIELDS.treatyCountry, data.treatyCountry);
  set(W8BEN_FIELDS.signDate, data.signedOn);
  set(W8BEN_FIELDS.printName, data.signerName);

  if (data.ftinNotRequired) {
    const box = form.getCheckBox(W8BEN_PREFIX + "c1_01[0]");
    box.check();
    box.defaultUpdateAppearances();
    box.enableReadOnly();
  }

  if (data.signingForAnother) {
    const box = form.getCheckBox(W8BEN_PREFIX + "c1_02[0]");
    box.check();
    box.defaultUpdateAppearances();
    box.enableReadOnly();
  }

  // The signature widget has no appearance stream — both flatten() and
  // removeField() throw on it — so the signature is drawn onto the page over
  // where the widget sits, and the form is left unflattened but read-only.
  const page = doc.getPage(0);
  const italic = await doc.embedFont(StandardFonts.HelveticaOblique);
  page.drawText(`/s/ ${data.signerName}`, { x: 112, y: 78, size: 10, font: italic });

  const bytes = await doc.save();
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  return { bytes, sha256 };
}

/** The caps the PDF itself enforces, so the form can validate before signing. */
export const W8BEN_LIMITS = {
  usTin: 11,
  dateOfBirth: 10,
  signedOn: 10,
} as const;

/** MM-DD-YYYY, which is the format printed on the form. */
export function toIrsDate(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${m}-${d}-${y}`;
}

// ─────────────────────────────────────────────────────────────
// Form W-9 (Rev. March 2024)
// ─────────────────────────────────────────────────────────────

// The list lives in lib/irs-forms-shared.ts so the browser can use it too.
export { W9_CLASSIFICATIONS, type W9Classification } from "@/lib/irs-forms-shared";

export type W9Data = {
  name: string;
  businessName?: string;
  classification: W9Classification;
  /** C, S or P — required when the classification is LLC. */
  llcTaxClassification?: string;
  /** The free text beside "Other (see instructions)". */
  otherClassification?: string;
  /** Line 3b: foreign partners, owners or beneficiaries. */
  foreignPartners?: boolean;
  exemptPayeeCode?: string;
  fatcaCode?: string;
  street: string;
  cityStateZip: string;
  requester?: string;
  accountNumbers?: string;
  /** Nine digits, no punctuation. Exactly one of ssn or ein. */
  ssn?: string;
  ein?: string;
  signerName: string;
  /** MM-DD-YYYY. */
  signedOn: string;
};

/** Confirmed against the labelled sample. Page 1 of Form W-9. */
const W9_FIELDS = {
  name: "f1_01[0]",
  businessName: "f1_02[0]",
  llcTaxClassification: "Boxes3a-b_ReadOrder[0].f1_03[0]",
  otherClassification: "Boxes3a-b_ReadOrder[0].f1_04[0]",
  exemptPayeeCode: "f1_05[0]",
  fatcaCode: "f1_06[0]",
  street: "Address_ReadOrder[0].f1_07[0]",
  cityStateZip: "Address_ReadOrder[0].f1_08[0]",
  requester: "f1_09[0]",
  accountNumbers: "f1_10[0]",
  ssn1: "f1_11[0]",
  ssn2: "f1_12[0]",
  ssn3: "f1_13[0]",
  ein1: "f1_14[0]",
  ein2: "f1_15[0]",
} as const;

/** Line 3a boxes, indexed the same as W9_CLASSIFICATIONS. */
const W9_CLASS_BOXES = [0, 1, 2, 3, 4, 5, 6].map(
  (i) => `Boxes3a-b_ReadOrder[0].c1_1[${i}]`,
);
const W9_FOREIGN_PARTNERS_BOX = "Boxes3a-b_ReadOrder[0].c1_2[0]";

const W9_PREFIX = "topmostSubform[0].Page1[0].";

export async function fillW9(data: W9Data): Promise<FilledForm> {
  const source = await readFile(path.join(FORM_DIR, "fw9.pdf"));
  const doc = await PDFDocument.load(source, { ignoreEncryption: true });
  const form = doc.getForm();
  const helvetica = await doc.embedFont(StandardFonts.Helvetica);

  const set = (field: string, value: string | undefined) => {
    if (!value) return;
    const f = form.getTextField(W9_PREFIX + field);
    const max = f.getMaxLength();
    f.setText(max ? value.slice(0, max) : value);
    f.updateAppearances(helvetica);
    f.enableReadOnly();
  };

  const check = (field: string) => {
    const box = form.getCheckBox(W9_PREFIX + field);
    box.check();
    box.defaultUpdateAppearances();
    box.enableReadOnly();
  };

  set(W9_FIELDS.name, data.name);
  set(W9_FIELDS.businessName, data.businessName);

  const classIndex = W9_CLASSIFICATIONS.indexOf(data.classification);
  if (classIndex < 0) throw new Error(`Unknown W-9 classification: ${data.classification}`);
  check(W9_CLASS_BOXES[classIndex]);
  if (data.classification === "LLC") set(W9_FIELDS.llcTaxClassification, data.llcTaxClassification);
  if (data.classification === "Other") set(W9_FIELDS.otherClassification, data.otherClassification);
  if (data.foreignPartners) check(W9_FOREIGN_PARTNERS_BOX);

  set(W9_FIELDS.exemptPayeeCode, data.exemptPayeeCode);
  set(W9_FIELDS.fatcaCode, data.fatcaCode);
  set(W9_FIELDS.street, data.street);
  set(W9_FIELDS.cityStateZip, data.cityStateZip);
  set(W9_FIELDS.requester, data.requester);
  set(W9_FIELDS.accountNumbers, data.accountNumbers);

  // Part I. The number goes in one row or the other, never both: a form
  // carrying two numbers does not say which one to report under.
  if (data.ssn && data.ein) {
    throw new Error("A W-9 carries either an SSN or an EIN, not both.");
  }
  if (data.ssn) {
    const d = data.ssn.replace(/\D/g, "");
    set(W9_FIELDS.ssn1, d.slice(0, 3));
    set(W9_FIELDS.ssn2, d.slice(3, 5));
    set(W9_FIELDS.ssn3, d.slice(5, 9));
  }
  if (data.ein) {
    const d = data.ein.replace(/\D/g, "");
    set(W9_FIELDS.ein1, d.slice(0, 2));
    set(W9_FIELDS.ein2, d.slice(2, 9));
  }

  // Part II has no fields at all — the signature and date lines on this form
  // are printed rules, not widgets — so both are drawn onto the page.
  const page = doc.getPage(0);
  const italic = await doc.embedFont(StandardFonts.HelveticaOblique);
  page.drawText(`/s/ ${data.signerName}`, { x: 150, y: 196, size: 10, font: italic });
  page.drawText(data.signedOn, { x: 425, y: 196, size: 10, font: helvetica });

  const bytes = await doc.save();
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  return { bytes, sha256 };
}

/** The caps the PDF itself enforces, so the form can validate before signing. */
export const W9_LIMITS = {
  llcTaxClassification: 1,
  ssn: 9,
  ein: 9,
} as const;
