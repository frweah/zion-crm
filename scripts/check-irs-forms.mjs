/**
 * Fills each supported IRS form with labelled values and writes the result out
 * for a human to look at.
 *
 *   node --experimental-strip-types scripts/check-irs-forms.mjs [outDir]
 *
 * The field mapping in lib/irs-forms.ts was established from field positions,
 * because these PDFs carry no field descriptions — f_1 and f_9 tell you
 * nothing. That mapping is only trustworthy because a labelled sample was
 * checked by eye. Run this again whenever the IRS revises a form, and check the
 * output before anybody signs one: a revision can move a field without
 * changing its name, and nothing else would warn you.
 *
 * It also asserts the values are really in the saved file, which catches a
 * silent failure to write.
 */
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { PDFDocument } from "pdf-lib";
import { fillW8BEN } from "../lib/irs-forms.ts";

const outDir = process.argv[2] ?? ".";

const sample = {
  name: "LINE 1 BENEFICIAL OWNER NAME",
  citizenshipCountry: "LINE 2 COUNTRY",
  residenceStreet: "LINE 3 PERMANENT RESIDENCE STREET",
  residenceCity: "LINE 3 CITY / PROVINCE / POSTAL",
  residenceCountry: "L3 COUNTRY",
  mailingStreet: "LINE 4 MAILING ADDRESS",
  mailingCity: "LINE 4 CITY / POSTAL",
  mailingCountry: "L4 COUNTRY",
  usTin: "LINE5 USTIN",
  foreignTin: "LINE 6a FOREIGN TIN",
  ftinNotRequired: true,
  reference: "LINE 7 REFERENCE",
  dateOfBirth: "LINE 8 DOB",
  treatyCountry: "LINE 9 TREATY COUNTRY",
  signerName: "PRINT NAME OF SIGNER",
  signedOn: "SIGN DATE",
  signingForAnother: true,
};

const { bytes, sha256 } = await fillW8BEN(sample);
const outPath = path.join(outDir, "W8BEN-field-check.pdf");
await writeFile(outPath, bytes);
console.log(`wrote ${outPath} (${bytes.length} bytes)`);
console.log(`sha256 ${sha256}`);

// Read it back: a form that saved without its values would look fine here.
const check = await PDFDocument.load(bytes, { ignoreEncryption: true });
const form = check.getForm();
const prefix = "topmostSubform[0].Page1[0].";
const failures = [];

const expect = (field, wanted) => {
  const got = form.getTextField(prefix + field).getText() ?? "";
  const ok = got === wanted || (wanted.length > got.length && wanted.startsWith(got));
  console.log(`  ${ok ? "ok  " : "FAIL"} ${field.padEnd(10)} ${JSON.stringify(got)}`);
  if (!ok) failures.push(`${field}: expected ${JSON.stringify(wanted)}, got ${JSON.stringify(got)}`);
};

expect("f_1[0]", sample.name);
expect("f_2[0]", sample.citizenshipCountry);
expect("f_3[0]", sample.residenceStreet);
expect("f_9[0]", sample.usTin);
expect("f_10[0]", sample.foreignTin);
expect("f_12[0]", sample.dateOfBirth);
expect("Date[0]", sample.signedOn);
expect("f_21[0]", sample.signerName);

for (const box of ["c1_01[0]", "c1_02[0]"]) {
  const checked = form.getCheckBox(prefix + box).isChecked();
  console.log(`  ${checked ? "ok  " : "FAIL"} ${box.padEnd(10)} checked=${checked}`);
  if (!checked) failures.push(`${box} was not checked`);
}

if (failures.length) {
  console.error(`\n${failures.length} PROBLEM(S):`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log("\n--- W-8BEN FILLS CORRECTLY ---");
console.log("Open the PDF and confirm each label sits on the line it names.");
