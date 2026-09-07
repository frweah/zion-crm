/**
 * Builds a sample Copy B and the two filing files, and checks them.
 *
 *   node --conditions=react-server --experimental-strip-types scripts/check-1099.mjs [outDir]
 *
 * Copy B is drawn rather than filled into an IRS template, so nothing warns you
 * if a box caption or the required notice goes missing in an edit. This reads
 * the text back out of the finished PDF and asserts the parts that a substitute
 * statement must carry.
 *
 * It also checks the thing that would be worst to get wrong quietly: that the
 * recipient's taxpayer number is truncated on the statement and complete in the
 * filing files.
 */
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { PDFDocument, PDFArray, decodePDFRawStream } from "pdf-lib";
import { buildCopyB, buildGenericCsv, buildIrisCsv } from "../lib/form-1099.ts";

const outDir = process.argv[2] ?? ".";
const failures = [];

const payer = {
  name: "Zion Vocational Rehabilitation Center",
  address: "2880 S Main Street Ste 105\nSalt Lake City, UT 84115",
  phone: "801-657-6671",
  ein: "987654321",
};

const recipient = {
  id: "r1",
  legalName: "Sample Contractor",
  businessName: "Sample Contracting LLC",
  addressSnapshot: "14 Example Road, Apt 3, Provo, UT, 84601",
  tinType: "SSN",
  tinLast4: "6789",
  nonemployeeComp: 4250.75,
};

// ── Copy B ───────────────────────────────────────────────────
const copyB = await buildCopyB(2026, payer, recipient);
const copyBPath = path.join(outDir, "1099-NEC-CopyB-sample.pdf");
await writeFile(copyBPath, copyB.bytes);
console.log(`wrote ${copyBPath} (${copyB.bytes.length} bytes)`);
console.log(`sha256 ${copyB.sha256}`);

// pdf-lib cannot read text back, so the check reads the page content stream,
// which is where drawText puts it. Two layers have to come off first: the
// stream is Flate-compressed, and pdf-lib writes every string as a hex literal
// rather than as characters. Skip either and the file contains none of the
// words that are plainly printed on it, so every check fails for the wrong
// reason — and the one asserting a complete taxpayer number is absent would
// pass on an empty string, which is worse than failing.
async function pageText(bytes) {
  const d = await PDFDocument.load(bytes);
  let raw = "";
  for (const page of d.getPages()) {
    const node = page.node.context.lookup(page.node.Contents());
    const streams = node instanceof PDFArray
      ? node.asArray().map((r) => page.node.context.lookup(r))
      : [node];
    for (const s of streams) raw += Buffer.from(decodePDFRawStream(s).decode()).toString("latin1");
  }

  return [...raw.matchAll(/<([0-9A-Fa-f]+)>\s*Tj/g)]
    .map((m) => Buffer.from(m[1], "hex").toString("latin1"))
    .join("\n");
}

const doc = await PDFDocument.load(copyB.bytes);
const raw = await pageText(copyB.bytes);
if (raw.length < 500) {
  console.error("The decoded page content is suspiciously short — the checks below would be meaningless.");
  process.exit(1);
}

const expectIn = (needle, why) => {
  const ok = raw.includes(needle);
  console.log(`  ${ok ? "ok  " : "FAIL"} ${why}`);
  if (!ok) failures.push(`${why} — "${needle}" is not in the PDF`);
};

const expectNotIn = (needle, why) => {
  const ok = !raw.includes(needle);
  console.log(`  ${ok ? "ok  " : "FAIL"} ${why}`);
  if (!ok) failures.push(`${why} — "${needle}" IS in the PDF`);
};

expectIn("1099-NEC", "the form is named");
expectIn("2026", "the tax year is on it");
expectIn("Copy B", "it says which copy it is");
expectIn("1545-0116", "the OMB number is on it");
expectIn("Nonemployee compensation", "box 1 is captioned");
expectIn("Federal income tax withheld", "box 4 is captioned");
expectIn("State tax withheld", "box 5 is captioned");
expectIn("State income", "box 7 is captioned");
expectIn("PAYER'S TIN", "the payer TIN box is there");
expectIn("RECIPIENT'S TIN", "the recipient TIN box is there");
expectIn("98-7654321", "the payer EIN is printed in full, as it must be");
expectIn("4,250.75", "box 1 carries the amount");
expectIn("Sample Contractor", "the recipient is named");
expectIn("furnished to the IRS", "the required notice is on it");
expectIn("Instructions for Recipient", "the recipient instructions are on it");
expectIn("Publication 1179", "it says what it is a substitute under");

// The whole point of a truncated TIN on a payee statement.
expectIn("XXX-XX-6789", "the recipient number is truncated");
expectNotIn("123456789", "no complete recipient number is on the statement");

if (doc.getPageCount() !== 1) {
  failures.push(`Copy B came to ${doc.getPageCount()} pages, expected 1`);
  console.log(`  FAIL one page per recipient (got ${doc.getPageCount()})`);
} else {
  console.log("  ok   one page per recipient");
}

const corrected = await buildCopyB(2026, payer, { ...recipient, corrected: true });
const correctedRaw = await pageText(corrected.bytes);
if (!correctedRaw.includes("CORRECTED")) {
  failures.push("a corrected statement is not marked CORRECTED");
  console.log("  FAIL a corrected statement is marked CORRECTED");
} else {
  console.log("  ok   a corrected statement is marked CORRECTED");
}

// ── filing files ─────────────────────────────────────────────
const filingRows = [{ ...recipient, tin: "123456789" }];

const generic = buildGenericCsv(2026, payer, filingRows);
const iris = buildIrisCsv(2026, payer, filingRows);

await writeFile(path.join(outDir, "1099-NEC-filing-sample.csv"), generic);
await writeFile(path.join(outDir, "1099-NEC-IRIS-sample.csv"), iris);
console.log(`\nwrote the two filing files to ${outDir}`);

const csvCheck = (name, text, checks) => {
  const [header, ...rows] = text.trim().split("\r\n");
  console.log(`\n${name}: ${header.split(",").length} columns, ${rows.length} row(s)`);
  for (const [why, ok] of checks(header, rows[0] ?? "")) {
    console.log(`  ${ok ? "ok  " : "FAIL"} ${why}`);
    if (!ok) failures.push(`${name}: ${why}`);
  }
};

csvCheck("filing CSV", generic, (header, row) => [
  ["the taxpayer number is complete, because a filing needs it", row.includes("123456789")],
  ["the address is split into its parts", row.includes("Provo") && row.includes("84601")],
  ["the street keeps its second line", row.includes("14 Example Road, Apt 3")],
  ["box 1 is the amount paid", row.includes("4250.75")],
  ["the payer EIN is formatted", row.includes("98-7654321")],
  ["a comma inside a value is quoted", row.includes('"14 Example Road, Apt 3"')],
  ["the header names the boxes", header.includes("box_1_nonemployee_compensation")],
]);

csvCheck("IRIS CSV", iris, (header, row) => [
  ["the taxpayer number is complete", row.includes("123456789")],
  ["the number type is stated", row.includes("SSN")],
  ["the payer block is filled", row.includes("Salt Lake City")],
  ["the recipient state is carried", row.includes("UT")],
  ["box 1 is the amount paid", row.includes("4250.75")],
  ["the header uses the portal's field names", header.includes("Nonemployee Compensation")],
]);

console.log("\n  --  The IRIS header row is the 1099-NEC field set as understood when this");
console.log("      was written. Check it against the current IRS template before the first");
console.log("      upload. Nothing in the file would tell you the template had moved.");

if (failures.length) {
  console.error(`\n${failures.length} PROBLEM(S):`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log("\n--- 1099 COPY B AND FILING FILES CHECK OUT ---");
console.log("Open the sample PDF and read it as a contractor would.");
