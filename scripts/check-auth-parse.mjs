/**
 * Reading a USOR authorization, checked against a made-up one.
 *
 *   node --experimental-strip-types scripts/check-auth-parse.mjs [outDir]
 *
 * Builds an authorization in the shape USOR uses, reads it back through the
 * real text extraction and the real rules, and asserts every field. The names
 * and numbers are invented — no client's authorization is in this repository
 * and none ever will be.
 *
 * This proves the pipeline, not the field mapping. Like the IRS forms, the
 * mapping is only trustworthy once a real form has been read and checked by
 * eye: a label that says "Units" instead of "Total hours", or a value in a box
 * to the right instead of underneath, is exactly what these rules will miss.
 * Run this after any change to the rules, and check a real one by hand before
 * anybody relies on it.
 *
 * It writes the sample PDF out so a human can look at what was parsed.
 */
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { PDFDocument, StandardFonts } from "pdf-lib";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { groupIntoLines } from "../lib/pdf-lines.ts";
import { parseAuthorizationText, toIsoDate, REQUIRED } from "../lib/authorization-parse.ts";

const outDir = process.argv[2] ?? ".";
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

// ── a form in the shape of a USOR authorization ──────────────
// Two columns, labels left, values right — the layout that makes a naive
// "split on the colon" parser fall over.
const SAMPLE = [
  ["", "UTAH STATE OFFICE OF REHABILITATION"],
  ["", "AUTHORIZATION FOR SERVICES"],
  ["Authorization #:", "VR-2026-004417"],
  ["Client Name:", "Jordan A. Sample"],
  ["USOR ID:", "8842190"],
  ["Counselor:", "Dana Fictional"],
  ["Office:", "Salt Lake City"],
  ["Service Type:", "Job Coaching"],
  ["Total Hours:", "40"],
  ["Rate:", "$45.00"],
  ["Start Date:", "03/02/2026"],
  ["End Date:", "09/30/2026"],
  ["Vendor:", "Zion Vocational Rehabilitation Center"],
];

async function buildSample() {
  const doc = await PDFDocument.create();
  const page = doc.addPage([612, 792]);
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  let y = 720;
  for (const [label, value] of SAMPLE) {
    if (!label) {
      page.drawText(value, { x: 150, y, size: 13, font: bold });
      y -= 26;
      continue;
    }
    page.drawText(label, { x: 60, y, size: 11, font });
    page.drawText(value, { x: 230, y, size: 11, font });
    y -= 22;
  }

  // A label above its box, which is the other layout these forms use.
  y -= 14;
  page.drawText("Authorized Services Description", { x: 60, y, size: 11, font });
  page.drawText("Job coaching supports at the worksite", { x: 60, y: y - 16, size: 11, font });

  return doc.save();
}

async function readBack(bytes) {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const require_ = createRequire(import.meta.url);
  pdfjs.GlobalWorkerOptions.workerSrc = pathToFileURL(
    require_.resolve("pdfjs-dist/legacy/build/pdf.worker.mjs"),
  ).href;

  const doc = await pdfjs.getDocument({
    // A copy: pdf.js takes ownership of the buffer and detaches it, so the
    // caller's bytes would be unusable afterwards.
    data: new Uint8Array(bytes),
    isEvalSupported: false,
    useSystemFonts: false,
    disableAutoFetch: true,
    disableStream: true,
    standardFontDataUrl: pathToFileURL(
      path.join(path.dirname(require_.resolve("pdfjs-dist/package.json")), "standard_fonts") +
        path.sep,
    ).href,
  }).promise;

  const lines = [];
  for (let p = 1; p <= doc.numPages; p++) {
    const page = await doc.getPage(p);
    const viewport = page.getViewport({ scale: 1 });
    const content = await page.getTextContent();
    const words = [];
    for (const raw of content.items) {
      const text = (raw.str ?? "").replace(/\s+/g, " ");
      if (!text.trim() || !raw.transform) continue;
      words.push({ x: raw.transform[4], y: viewport.height - raw.transform[5], text });
    }
    lines.push(...groupIntoLines(words, p));
  }

  const plain = lines.map((l) => l.text).join("\n");
  return { plain, pages: doc.numPages, scanned: plain.replace(/\s/g, "").length < 40 };
}

// ── the dates, before anything else ──────────────────────────
const dates = [
  ["03/02/2026", "2026-03-02"],
  ["3/2/26", "2026-03-02"],
  ["2026-03-02", "2026-03-02"],
  ["12/31/2025", "2025-12-31"],
  ["02/30/2026", null],
  ["13/01/2026", null],
  ["not a date", null],
];
for (const [raw, want] of dates) {
  const got = toIsoDate(raw);
  if (got !== want) fail(`toIsoDate(${JSON.stringify(raw)}) gave ${got}, expected ${want}`);
}
ok("US dates in three shapes become ISO, and the 30th of February does not");

// ── the whole pipeline ───────────────────────────────────────
const bytes = await buildSample();
const text = await readBack(bytes);

if (text.scanned) fail("a PDF with text in it was called a scan");
else ok("a PDF with a text layer is not mistaken for a scan");

const parsed = parseAuthorizationText(text.plain, { pages: text.pages, scanned: text.scanned });

const expected = {
  authNumber: "VR-2026-004417",
  clientName: "Jordan A. Sample",
  agencyId: "8842190",
  counselorName: "Dana Fictional",
  office: "Salt Lake City",
  serviceType: "Job Coaching",
  totalHours: "40",
  rate: "45.00",
  startDate: "2026-03-02",
  endDate: "2026-09-30",
  rateType: "Hourly",
};

for (const [key, want] of Object.entries(expected)) {
  const got = parsed.fields[key]?.value;
  if (got !== want) {
    fail(`${key} read as ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
  }
}
if (!problems.length) ok(`all ${Object.keys(expected).length} fields read from a two-column form`);

// ── every field says where it came from ──────────────────────
const unsourced = Object.entries(parsed.fields).filter(([, f]) => !f.source || !f.rule);
if (unsourced.length) {
  fail(`${unsourced.map(([k]) => k).join(", ")} came back with no source line`);
} else {
  ok("every value carries the line it came from and the rule that found it");
}

// ── a scan is named, not guessed at ──────────────────────────
const blank = await PDFDocument.create();
blank.addPage([612, 792]);
const blankText = await readBack(await blank.save());
const blankParsed = parseAuthorizationText(blankText.plain, {
  pages: blankText.pages,
  scanned: blankText.scanned,
});
if (!blankParsed.scanned) {
  fail("a PDF with no text was not recognised as a scan");
} else if (Object.keys(blankParsed.fields).length > 0) {
  fail("a scan produced field values out of nowhere");
} else if (!blankParsed.warnings.join(" ").includes("scan")) {
  fail("a scan does not say that it is one");
} else {
  ok("a file with no text is called a scan, invents nothing, and says what is needed");
}

// ── nonsense in, nothing out ─────────────────────────────────
const nonsense = parseAuthorizationText(
  "Dear Sir\nThank you for your letter of the 3rd\nWe will be in touch\n",
  { pages: 1, scanned: false },
);
if (nonsense.fields.rate || nonsense.fields.totalHours) {
  fail("a letter produced a rate or an hours figure");
} else {
  ok("a document that is not an authorization yields no rate and no hours");
}
for (const key of REQUIRED) {
  if (!nonsense.missing.includes(key)) fail(`${key} is not reported missing from a letter`);
}
ok("and reports the fields it could not find rather than leaving them blank quietly");

// ── the things worth saying out loud ─────────────────────────
const backwards = parseAuthorizationText(
  ["Client Name: Test Person", "Service Type: Job Coaching", "Rate: $45.00",
   "Start Date: 09/30/2026", "End Date: 03/02/2026"].join("\n"),
  { pages: 1, scanned: false },
);
if (!backwards.warnings.some((w) => w.includes("before the start date"))) {
  fail("an end date before the start date passed without comment");
} else {
  ok("an end date before the start date is called out, not silently accepted");
}

const silly = parseAuthorizationText(
  ["Client Name: Test Person", "Service Type: Job Coaching", "Rate: $54,000.00"].join("\n"),
  { pages: 1, scanned: false },
);
if (!silly.warnings.some((w) => w.includes("total rather than a rate"))) {
  fail("a rate of $54,000 passed without comment");
} else {
  ok("a rate that is obviously a total is queried");
}

// ── the sample, for a human to look at ───────────────────────
const out = path.join(outDir, "authorization-parse-sample.pdf");
await writeFile(out, bytes);
console.log(`\n  wrote ${out} — the form these rules were checked against`);

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- AUTHORIZATION PARSING VERIFIED (against a made-up form) ---");
