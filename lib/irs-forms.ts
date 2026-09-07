import "server-only";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import { PDFDocument, StandardFonts } from "pdf-lib";

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
