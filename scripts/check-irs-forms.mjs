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

// ─────────────────────────────────────────────────────────────
// Form W-9
// ─────────────────────────────────────────────────────────────
const { fillW9 } = await import("../lib/irs-forms.ts");

const w9Sample = {
  name: "LINE 1 NAME OF ENTITY / INDIVIDUAL",
  businessName: "LINE 2 BUSINESS NAME",
  classification: "LLC",
  llcTaxClassification: "P",
  foreignPartners: true,
  exemptPayeeCode: "L4a",
  fatcaCode: "L4b FATCA",
  street: "LINE 5 ADDRESS, STREET, APT",
  cityStateZip: "LINE 6 CITY, STATE AND ZIP",
  requester: "REQUESTER NAME AND ADDRESS",
  accountNumbers: "LINE 7 ACCOUNT NUMBERS",
  ssn: "123456789",
  signerName: "SIGNER NAME",
  signedOn: "09-07-2026",
};

const w9 = await fillW9(w9Sample);
const w9Path = path.join(outDir, "W9-field-check.pdf");
await writeFile(w9Path, w9.bytes);
console.log(`\nwrote ${w9Path} (${w9.bytes.length} bytes)`);
console.log(`sha256 ${w9.sha256}`);

const w9Check = (await PDFDocument.load(w9.bytes, { ignoreEncryption: true })).getForm();
const w9Prefix = "topmostSubform[0].Page1[0].";
const w9Failures = [];

const w9Expect = (field, wanted) => {
  const got = w9Check.getTextField(w9Prefix + field).getText() ?? "";
  const ok = got === wanted || (wanted.length > got.length && wanted.startsWith(got));
  console.log(`  ${ok ? "ok  " : "FAIL"} ${field.padEnd(34)} ${JSON.stringify(got)}`);
  if (!ok) w9Failures.push(`${field}: expected ${JSON.stringify(wanted)}, got ${JSON.stringify(got)}`);
};

w9Expect("f1_01[0]", w9Sample.name);
w9Expect("f1_02[0]", w9Sample.businessName);
w9Expect("Boxes3a-b_ReadOrder[0].f1_03[0]", w9Sample.llcTaxClassification);
w9Expect("f1_05[0]", w9Sample.exemptPayeeCode);
w9Expect("f1_06[0]", w9Sample.fatcaCode);
w9Expect("Address_ReadOrder[0].f1_07[0]", w9Sample.street);
w9Expect("Address_ReadOrder[0].f1_08[0]", w9Sample.cityStateZip);
w9Expect("f1_09[0]", w9Sample.requester);
w9Expect("f1_10[0]", w9Sample.accountNumbers);
w9Expect("f1_11[0]", "123");
w9Expect("f1_12[0]", "45");
w9Expect("f1_13[0]", "6789");

// The LLC box, and only the LLC box, out of the seven on line 3a.
for (let i = 0; i < 7; i++) {
  const name = `Boxes3a-b_ReadOrder[0].c1_1[${i}]`;
  const checked = w9Check.getCheckBox(w9Prefix + name).isChecked();
  const wanted = i === 5;
  console.log(`  ${checked === wanted ? "ok  " : "FAIL"} c1_1[${i}] checked=${checked} (want ${wanted})`);
  if (checked !== wanted) w9Failures.push(`c1_1[${i}]: checked=${checked}, wanted ${wanted}`);
}
const fp = w9Check.getCheckBox(w9Prefix + "Boxes3a-b_ReadOrder[0].c1_2[0]").isChecked();
console.log(`  ${fp ? "ok  " : "FAIL"} c1_2[0] (line 3b) checked=${fp}`);
if (!fp) w9Failures.push("c1_2[0] was not checked");

// An EIN and an SSN together would leave the payer guessing which to report.
let refused = false;
try {
  await fillW9({ ...w9Sample, ein: "987654321" });
} catch {
  refused = true;
}
console.log(`  ${refused ? "ok  " : "FAIL"} refuses an SSN and an EIN on the same form`);
if (!refused) w9Failures.push("fillW9 accepted both an SSN and an EIN");

if (w9Failures.length) {
  console.error(`\n${w9Failures.length} W-9 PROBLEM(S):`);
  for (const f of w9Failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log("\n--- W-9 FILLS CORRECTLY ---");
console.log("Open the PDF and confirm each label sits on the line it names,");
console.log("and that the signature and date sit on the Part II rules.");
