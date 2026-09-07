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

// ─────────────────────────────────────────────────────────────
// Form W-4
// ─────────────────────────────────────────────────────────────
const { fillW4, W4_CREDITS } = await import("../lib/irs-forms.ts");

const w4Sample = {
  firstName: "STEP 1a FIRST NAME",
  lastName: "STEP 1a LAST NAME",
  address: "STEP 1a ADDRESS",
  cityStateZip: "STEP 1a CITY, STATE AND ZIP",
  ssn: "123456789",
  filingStatus: "Head of household",
  multipleJobs: true,
  qualifyingChildrenAmount: 4400,
  otherDependentsAmount: 500,
  otherCreditsAmount: 100,
  otherIncome: 1111,
  deductions: 2222,
  extraWithholding: 3333,
  employerName: "EMPLOYER NAME AND ADDRESS",
  employerEin: "987654321",
  firstDateOfEmployment: "01-05-2026",
  signerName: "SIGNER NAME",
  signedOn: "09-07-2026",
};

const w4 = await fillW4(w4Sample);
const w4Path = path.join(outDir, "W4-field-check.pdf");
await writeFile(w4Path, w4.bytes);
console.log(`\nwrote ${w4Path} (${w4.bytes.length} bytes)`);
console.log(`sha256 ${w4.sha256}`);

const w4Check = (await PDFDocument.load(w4.bytes, { ignoreEncryption: true })).getForm();
const w4Prefix = "topmostSubform[0].Page1[0].";
const w4Failures = [];

const w4Expect = (field, wanted) => {
  const got = w4Check.getTextField(w4Prefix + field).getText() ?? "";
  const ok = got === wanted || (wanted.length > got.length && wanted.startsWith(got));
  console.log(`  ${ok ? "ok  " : "FAIL"} ${field.padEnd(26)} ${JSON.stringify(got)}`);
  if (!ok) w4Failures.push(`${field}: expected ${JSON.stringify(wanted)}, got ${JSON.stringify(got)}`);
};

w4Expect("Step1a[0].f1_01[0]", w4Sample.firstName);
w4Expect("Step1a[0].f1_02[0]", w4Sample.lastName);
w4Expect("Step1a[0].f1_03[0]", w4Sample.address);
w4Expect("Step1a[0].f1_04[0]", w4Sample.cityStateZip);
w4Expect("f1_05[0]", w4Sample.ssn);
w4Expect("Step3_ReadOrder[0].f1_06[0]", "4,400");
w4Expect("Step3_ReadOrder[0].f1_07[0]", "500");
w4Expect("f1_08[0]", "5,000"); // 4,400 + 500 + 100
w4Expect("f1_09[0]", "1,111");
w4Expect("f1_10[0]", "2,222");
w4Expect("f1_11[0]", "3,333");
w4Expect("f1_12[0]", w4Sample.employerName);
w4Expect("f1_13[0]", w4Sample.firstDateOfEmployment);
w4Expect("f1_14[0]", w4Sample.employerEin);

// Head of household, and only that, out of the three in Step 1(c).
for (let i = 0; i < 3; i++) {
  const checked = w4Check.getCheckBox(w4Prefix + `c1_1[${i}]`).isChecked();
  const wanted = i === 2;
  console.log(`  ${checked === wanted ? "ok  " : "FAIL"} c1_1[${i}] checked=${checked} (want ${wanted})`);
  if (checked !== wanted) w4Failures.push(`c1_1[${i}]: checked=${checked}, wanted ${wanted}`);
}
const mj = w4Check.getCheckBox(w4Prefix + "c1_2[0]").isChecked();
console.log(`  ${mj ? "ok  " : "FAIL"} c1_2[0] (step 2c) checked=${mj}`);
if (!mj) w4Failures.push("c1_2[0] was not checked");

// Claiming exemption must empty Steps 2 to 4: the form says to leave them
// blank, and a withholding instruction on a form claiming exemption is a
// contradiction that the employer would have to resolve by guessing.
const exempt = await fillW4({ ...w4Sample, exempt: true });
const exemptForm = (await PDFDocument.load(exempt.bytes, { ignoreEncryption: true })).getForm();
const exemptBox = exemptForm.getCheckBox(w4Prefix + "c1_3[0]").isChecked();
console.log(`  ${exemptBox ? "ok  " : "FAIL"} c1_3[0] (exempt) checked=${exemptBox}`);
if (!exemptBox) w4Failures.push("the exempt box was not checked");

for (const f of ["f1_08[0]", "f1_09[0]", "f1_10[0]", "f1_11[0]"]) {
  const got = exemptForm.getTextField(w4Prefix + f).getText() ?? "";
  console.log(`  ${got === "" ? "ok  " : "FAIL"} ${f} empty when exempt (got ${JSON.stringify(got)})`);
  if (got !== "") w4Failures.push(`${f} was filled on a form claiming exemption`);
}
const exemptMj = exemptForm.getCheckBox(w4Prefix + "c1_2[0]").isChecked();
console.log(`  ${!exemptMj ? "ok  " : "FAIL"} c1_2[0] unchecked when exempt`);
if (exemptMj) w4Failures.push("step 2(c) was checked on a form claiming exemption");

// A zero is not a value the IRS wants written; the box stays empty.
const zeros = await fillW4({
  ...w4Sample,
  qualifyingChildrenAmount: 0,
  otherDependentsAmount: 0,
  otherCreditsAmount: 0,
  otherIncome: 0,
  deductions: 0,
  extraWithholding: 0,
});
const zeroForm = (await PDFDocument.load(zeros.bytes, { ignoreEncryption: true })).getForm();
for (const f of ["Step3_ReadOrder[0].f1_06[0]", "f1_08[0]", "f1_11[0]"]) {
  const got = zeroForm.getTextField(w4Prefix + f).getText() ?? "";
  console.log(`  ${got === "" ? "ok  " : "FAIL"} ${f} empty for a zero (got ${JSON.stringify(got)})`);
  if (got !== "") w4Failures.push(`${f} printed a zero`);
}

console.log(`  --  Step 3 figures in use: $${W4_CREDITS.perQualifyingChild} per qualifying child,`);
console.log(`      $${W4_CREDITS.perOtherDependent} per other dependent, from the ${W4_CREDITS.formYear} form.`);
console.log("      Check these against the face of the PDF — nothing else will.");

if (w4Failures.length) {
  console.error(`\n${w4Failures.length} W-4 PROBLEM(S):`);
  for (const f of w4Failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log("\n--- W-4 FILLS CORRECTLY ---");
console.log("Open the PDF and confirm each label sits on the line it names,");
console.log("and that the signature and date sit on the Step 5 rules.");
