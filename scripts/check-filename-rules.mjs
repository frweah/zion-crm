/**
 * Filing by filename, checked.
 *
 *   node --experimental-strip-types scripts/check-filename-rules.mjs
 *
 * Every name below is invented, in the shapes the real folders use. No client's
 * name or authorization number appears here: the V-numbers start V0000, which
 * no USOR number does.
 *
 * The expensive mistakes are the ones checked hardest: an invoice put on the
 * wrong authorization, a monthly report dated the day somebody saved it, and a
 * note that looks dated from the document when the date is only the file's.
 */
import {
  readFilename,
  documentDate,
  chooseAuthorization,
  planDocument,
  proposedService,
  vKey,
} from "../lib/filename-rules.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function expect(name, client, want) {
  const r = readFilename(name, client);
  const bad = Object.entries(want).filter(([k, v]) => !eq(r[k], v));
  if (bad.length) fail(`"${name}": ${bad.map(([k, v]) => `${k} is ${JSON.stringify(r[k])}, expected ${JSON.stringify(v)}`).join("; ")}`);
  return r;
}

// ── Pattern A: authorizations ────────────────────────────────
expect("19 V0000101 JC.pdf", "", { pattern: "Authorization", vNumbers: ["V0000101"], families: ["Job Coaching"] });
expect("JC 10 V0000102.pdf", "", { pattern: "Authorization", vNumbers: ["V0000102"], families: ["Job Coaching"] });
expect("KL_v0000103 JD Feb.pdf", "", { pattern: "Authorization", vNumbers: ["V0000103"], families: ["Job Development"], month: { month: 2, year: null } });
expect("V0000104Sample JobPlacement.pdf", "", { pattern: "Authorization", vNumbers: ["V0000104"], families: ["Job Placement"] });
expect("Jordan Sample V0000105.pdf", "Jordan Sample", { pattern: "Authorization", vNumbers: ["V0000105"], families: [] });
expect("06 V000106 JP.pdf", "", { pattern: "Authorization", vNumbers: ["V000106"] });
expect("JS JD JPauth.pdf", "", { pattern: "Authorization", families: ["Job Development", "Job Placement"] });
expect("CE auth.pdf", "", { pattern: "Authorization", families: ["Job Placement"], supported: true });
expect("Discovery assement auth.pdf", "", { pattern: "Authorization", families: ["WSA"] });
expect("job coach auth noreply@utah.gov_20250912_111356.pdf", "", { pattern: "Authorization", families: ["Job Coaching"] });
expect("IO_v0000107 Life Skill auth.pdf", "", { pattern: "Authorization", vNumbers: ["V0000107"], families: ["Life Skills"] });
if (problems.length === 0) ok("authorization names: V-number and service read, the leading number and counselor initials ignored");

// ── Pattern B: invoices ──────────────────────────────────────
const before = problems.length;
expect("Invoice Job search V0000106 Sample and JobDevelopment.pdf", "", { pattern: "Invoice", vNumbers: ["V0000106"], families: ["Job Development"] });
expect("WSA billing BB_v0000107.pdf", "", { pattern: "Invoice", vNumbers: ["V0000107"], families: ["WSA"] });
expect("April invoice Job Coach hrs auth V0000108.pdf", "", { pattern: "Invoice", month: { month: 4, year: null } });
expect("JD invoice 2354_001.pdf", "", { pattern: "Invoice", families: ["Job Development"] });
expect("HQI billing.pdf", "", { pattern: "Invoice", hqIndicator: true, jobDevelopmentNamed: false });
expect("148 billable form.pdf", "", { pattern: "Billable hours form", category: "Signed USOR form" });
if (problems.length === before) ok("invoice names, including ones that also say \"auth\", are invoices; a USOR 148 is a form, not an invoice");

// ── Pattern C: narratives ────────────────────────────────────
const c0 = problems.length;
expect("Jan [USOR96] Jordan Sample.pdf", "Jordan Sample", { pattern: "Report", usor: "96", noteType: "Job search", periodic: true, month: { month: 1, year: null } });
expect("usor 96_Jordan Sample_March 2026.pdf", "Jordan Sample", { pattern: "Report", usor: "96", month: { month: 3, year: 2026 } });
expect("Jordan Aug job coach.pdf", "Jordan Sample", { pattern: "Report", noteType: "Coaching session", periodic: true, category: "Signed USOR form" });
expect("Jordan job dev may.pdf", "Jordan Sample", { pattern: "Report", noteType: "Job search", periodic: true });
expect("SE JC  July.pdf", "", { pattern: "Report", families: ["Job Coaching"], periodic: true });
expect("94 (WSA Referral - editable) Jordan Sample.pdf", "Jordan Sample", { pattern: "Report", usor: "94", noteType: "Counselor contact", restricted: true });
expect("WSA complete.pdf", "", { pattern: "Report", noteType: "Meeting", restricted: true });
expect("SampleJForm94.pdf", "", { pattern: "Report", usor: "94", restricted: true });
expect("placement for jordan 60.pdf", "Jordan Sample", { pattern: "Report", usor: "60", noteType: "Employer contact", periodic: false });
expect("Discovery and assessment.pdf", "", { pattern: "Report", restricted: true });
expect("Resume.pdf", "", { pattern: "Resume", noteType: "General", label: "Resume on file" });
expect("progress report.pdf", "", { pattern: "Report", noteType: "Job search" });
expect("VR case note.pdf", "", { pattern: "Report", noteType: "Counselor contact" });
expect("incident note.pdf", "", { pattern: "Report", noteType: "General" });
expect("Parks Maintenance Worker Feb'25.pdf", "", { pattern: "Report", noteType: "Job search", month: { month: 2, year: 2025 } });
expect("shelving observation.pdf", "", { pattern: "Report", noteType: "Coaching session" });
expect("19 Sample WSA sent 10-23.pdf", "", { pattern: "Report", sentMonthDay: { month: 10, day: 23 }, month: null });
expect("19 Sample, C. my portion of WSA sent 3-26-25.pdf", "", { exactDate: "2025-03-26" });
if (problems.length === c0) ok("narrative names: USOR number, activity type, restricted tier and period read from the name");

// ── names that say nothing ───────────────────────────────────
const d0 = problems.length;
expect("Receipt_2609111199571B09.pdf", "", { pattern: "Not a client document" });
expect("Stamped File Copy_26091.pdf", "", { pattern: "Not a client document" });
expect("2354_001.pdf", "", { pattern: "Nothing in the name" });
expect("1c00e490-5665-4977-9c92-e3482a031aff.pdf", "", { pattern: "Nothing in the name" });
expect("noreply@utah.gov_20250225_131722.pdf", "", { pattern: "Nothing in the name", exactDate: "2025-02-25" });
expect("Jordan file.pdf", "Jordan Sample", { pattern: "Nothing in the name" });
expect("SampleJordan (1).pdf", "Jordan Sample", { pattern: "Nothing in the name" });
expect("1902_001 JC.pdf", "", { pattern: "Service only" });
expect("Bookkeeping Certs-combined.pdf", "", { pattern: "Attach" });
if (problems.length === d0) ok("scanner numbers, random ids and bare client names are \"nothing in the name\", not guessed at");

// ── vKey ─────────────────────────────────────────────────────
if (vKey("V0001234C") !== "0001234" || vKey("v0001234") !== "0001234" || vKey("KL_V0001234") === "0001234") {
  fail(`vKey is wrong: ${vKey("V0001234C")} / ${vKey("v0001234")}`);
} else ok("V0001234, v0001234 and V0001234C are one number; issue letters do not make a different one");

// ── dates ────────────────────────────────────────────────────
const doc = (over = {}) => ({ text: "", fields: {}, fileModified: "2026-03-05T18:00:00Z", today: "2026-09-13", ...over });
const date = (name, over) => documentDate(readFilename(name), doc(over));
const dateCases = [
  ["Aug job coach.pdf", { fileModified: "2026-03-05T18:00:00Z" }, "2025-08-31", "Period covered", "a month after the file was saved is last year's"],
  ["Feb job coach.pdf", {}, "2026-02-28", "Period covered", "a month named without a year is the last one before the file was saved"],
  ["Dec job dev.pdf", { fileModified: "2026-01-10T18:00:00Z" }, "2025-12-31", "Period covered", "December saved in January is last December"],
  ["USOR 96.pdf", { fields: { MonthYear: "March 2026" } }, "2026-03-31", "Period covered", "a USOR 96's MonthYear field gives its month"],
  ["USOR 95 tracker.pdf", { fields: { "Month/Year": "04/26" } }, "2026-04-30", "Period covered", "a USOR 95's Month/Year of mm/yy gives its month"],
  ["USOR 93.pdf", { fields: { Date: "05/14/2026" } }, "2026-05-31", "Period covered", "a USOR 93 with no month field is the month of its dates"],
  ["September job coach.pdf", { fileModified: "2026-09-10T18:00:00Z" }, "2026-09-13", "Period covered", "a month still running is dated today, never ahead"],
  ["USOR 93.pdf", {}, "2026-03-05", "File date (fallback)", "a monthly report with no month anywhere falls back to the file date, and says so"],
  ["placement 60.pdf", { fields: { Date: "06/03/2026" } }, "2026-06-03", "Read from the document", "a placement report takes the date on the form"],
  ["progress report.pdf", { text: "Report date: March 3, 2026\nBody" }, "2026-03-03", "Read from the document", "a narrative takes a date written in it"],
  ["summary report.pdf", {}, "2026-03-05", "File date (fallback)", "a narrative with no date anywhere is the file date, marked"],
  ["Scan_20250211 notes.pdf", {}, "2025-02-11", "Named in the file", "a full date in the name wins"],
  ["WSA sent 10-23.pdf", { fileModified: "2025-10-29T18:00:00Z" }, "2025-10-23", "Named in the file", "\"sent 10-23\" is 23 October"],
  ["progress report.pdf", { text: "Date: 12/01/2027" }, "2026-03-05", "File date (fallback)", "a date in the future is not believed"],
];
const dt0 = problems.length;
for (const [name, over, at, from, what] of dateCases) {
  const d = date(name, over);
  if (d.at !== at || d.datedFrom !== from) fail(`dates: ${what} — "${name}" gave ${d.at} (${d.datedFrom}), expected ${at} (${from})`);
}
if (problems.length === dt0) ok(`${dateCases.length} dating rules: the period covered, the name, the document, and the file date only as a marked fallback`);

// ── which authorization ──────────────────────────────────────
const A = (id, number, service, start = null, end = null) => ({ id, number, service_type: service, status: "Open", start_date: start, end_date: end });
const choose = (name, auths, over = {}) =>
  chooseAuthorization(readFilename(name), { text: "", auths, numbersElsewhere: [], date: null, month: null, ...over });

const auth0 = problems.length;
let c = choose("19 V0000301 JC.pdf", [A("a", "V0000301", "Job Coaching"), A("b", "V0000302", "Job Coaching")]);
if (c.kind !== "linked" || c.auth.id !== "a") fail(`the V-number in the name did not decide (${c.kind})`);

c = choose("V0000310 job coach May.pdf", [
  A("A", "V0000310A", "Job Coaching", "2026-01-01", "2026-03-31"),
  A("B", "V0000310B", "Job Coaching", "2026-04-01", "2026-06-30"),
], { month: { month: 5, year: 2026 } });
if (c.kind !== "linked" || c.auth.id !== "B") fail(`May did not pick the issue whose dates cover May (${c.kind} ${c.auth?.id})`);

c = choose("V0000310 job coach.pdf", [A("A", "V0000310A", "Job Coaching"), A("B", "V0000310B", "Job Coaching")]);
if (c.kind !== "pick" || c.choices.length !== 2) fail("two issues of a number with nothing to tell them apart were not left to a person");

c = choose("17 V0000320 JC.pdf", [A("x", "V0000999", "Job Coaching")]);
if (c.kind !== "new" || c.number !== "V0000320") fail("a V-number not on file was not proposed as a new authorization");

c = choose("17 V0000321 JC.pdf", [], { numbersElsewhere: ["0000321"] });
if (c.kind !== "pick") fail("a V-number on file for another client was not stopped");

c = choose("17 V0000322 JD.pdf", [A("x", "V0000322", "Job Coaching")]);
if (c.kind !== "pick" || !/Job Development/.test(c.why)) fail("a name and a record that disagree about the service were linked anyway");

c = choose("job coach invoice.pdf", [A("j", "V0000330", "Job Coaching"), A("d", "V0000331", "Job Development + HQ Indicator")]);
if (c.kind !== "linked" || c.auth.id !== "j") fail("the only authorization for the named service did not decide");

c = choose("JD invoice.pdf", [A("d", "V0000332", "Job Development + HQ Indicator"), A("j", "V0000333", "Job Coaching")]);
if (c.kind !== "linked" || c.auth.id !== "d") fail("JD did not find a Job Development + HQ Indicator authorization");

c = choose("job coach invoice.pdf", [A("1", "V0000340", "Job Coaching"), A("2", "V0000341", "Job Coaching")], { text: "Authorization V0000341 hours" });
if (c.kind !== "linked" || c.auth.id !== "2") fail("a V-number in the document's text did not decide between two");

c = choose("job coach invoice.pdf", [
  A("1", "V0000350", "Job Coaching", "2025-01-01", "2025-06-30"),
  A("2", "V0000351", "Job Coaching", "2025-07-01", "2025-12-31"),
], { date: "2025-08-15" });
if (c.kind !== "linked" || c.auth.id !== "2") fail("the document's date inside one authorization's dates did not decide");

c = choose("job coach invoice.pdf", [A("1", "V0000360", "Job Coaching"), A("2", "V0000361", "Job Coaching")]);
if (c.kind !== "pick" || c.choices.length !== 2) fail("two authorizations for the service and nothing else to go on were not left to a person");

c = choose("JC JP JS auth.pdf", [A("1", "V0000370", "Job Coaching")]);
if (c.kind !== "pick") fail("a file naming several services was put on one authorization");

c = choose("job coach auth.pdf", [A("j", "V0000390", "Job Coaching")], { text: "AUTHORIZATION\nA U T H N U M V 0 0 0 0 3 9 1\nBegin: 05/07/2025" });
if (c.kind !== "new" || c.number !== "V0000391") fail(`a scan showing a number not on file was put on "the only one for the service" instead of waiting as that authorization (${c.kind}: ${c.why ?? c.how})`);

c = choose("placement auth.pdf", [
  A("1", "V0000500", "Job Placement", "2025-11-01", "2026-05-01"),
  A("2", "V0000501", "Job Placement", "2024-01-01", "2024-06-30"),
], { text: "A U T H N U M V 0 0 0 0 5 0 8", date: "2025-12-01" });
if (c.kind !== "new" || c.number !== "V0000508") fail(`a scan showing its own number, not on file, was put on the authorization whose dates cover it (${c.kind})`);

c = choose("invoice.pdf", [A("1", "V0000510", "Job Coaching", "2025-01-01", "2025-12-31")], { text: "AUTHNUMV0000519 billing", date: "2025-06-01" });
if (c.kind !== "pick") fail("an invoice showing an authorization number not on file was billed against another by its dates");

c = choose("SE JC auth.pdf", [
  A("1", "V0000520", "Job Coaching", "2026-01-01", "2026-08-01"),
  A("2", "V0000521", "Job Coaching", "2025-01-01", "2025-06-01"),
  A("3", "V0000522", "Job Placement"),
], { text: "AUTHNUMV0000522", date: "2026-02-01" });
if (c.kind !== "pick" || !/V0000522.*Job Placement/.test(c.why)) fail(`a scan showing an on-file number for another service was linked by its dates (${c.kind}: ${c.why ?? c.how})`);

c = choose("auth scan.pdf", [A("j", "V0000530", "Job Coaching")], { text: "A U T H N U M V 0 0 0 0 5 3\nAUTHNUMV0000539" });
if (c.kind !== "new" || c.number !== "V0000539") fail(`of two readings of one number, the truncated one was proposed (${c.kind}: ${c.number})`);

c = choose("job coach auth.pdf", [A("j", "V0000390", "Job Coaching")], { text: "AUTHNUMV0000390\nBegin: 05/07/2025" });
if (c.kind !== "linked" || c.auth.id !== "j") fail("a scan showing its own authorization's number, glued to its label, was not linked");

c = choose("placement invoice.pdf", [A("1", "V0000380", "Job Coaching")]);
if (c.kind !== "pick" || !/^no Job Placement authorization on file \(1 other authorization\)$/.test(c.why)) {
  fail(`an invoice for a service with no authorization on file was put somewhere or misdescribed (${c.kind}: ${c.why})`);
}
if (problems.length === auth0) ok("which authorization: V-number, issue by month, the only one for the service, the number in the text, the dates — and a person for the rest");

// ── proposed service ─────────────────────────────────────────
const s0 = problems.length;
const svc = (name, text = "") => proposedService(readFilename(name), text, {});
if (svc("CE auth.pdf") !== "Job Placement (SE)") fail(`CE should be Job Placement (SE), got ${svc("CE auth.pdf")}`);
if (svc("CIE 60 auth.pdf") !== "Job Placement") fail("CIE should be Job Placement");
if (svc("JS auth.pdf") !== "Job Development") fail("JS should be Job Development");
if (svc("JD HQI auth.pdf") !== "Job Development + HQ Indicator") fail(`JD with HQI should be Job Development + HQ Indicator, got ${svc("JD HQI auth.pdf")}`);
if (svc("Discovery auth.pdf") !== null) fail("a WSA with no tier anywhere should not guess one");
if (svc("WSA auth.pdf", "Tier 2 assessment") !== "WSA Tier 2") fail("a WSA whose text says Tier 2 should be WSA Tier 2");
if (problems.length === s0) ok("services: JS is job development, CE is Job Placement (SE), CIE placement, and a WSA tier only when the document says");

// ── the plan ─────────────────────────────────────────────────
const base = {
  clientName: "Jordan Sample", fileModified: "2026-03-05T18:00:00Z", today: "2026-09-13",
  textKind: "Unreadable", textUsor: null, text: "", fields: {}, parsedAuth: null,
  auths: [A("j", "V0000400", "Job Coaching"), A("p", "V0000401", "Job Placement")], numbersElsewhere: [],
};
const plan = (over) => planDocument({ ...base, ...over });
const p0 = problems.length;

let p = plan({ filename: "anything.pdf", textKind: "Warrant" });
if (p.action !== "leave") fail("a warrant was filed by its name");

p = plan({ filename: "2354_001.pdf", textKind: "USOR form", textUsor: "95", fields: { "Month/Year": "02/26" } });
if (p.action !== "note" || p.noteType !== "Coaching session" || p.at !== "2026-02-28" || p.datedFrom !== "Period covered") {
  fail(`a scanner-named USOR 95 was not filed from its text (${p.action} ${p.at} ${p.datedFrom})`);
}

p = plan({ filename: "2354_001.pdf", textKind: "Other" });
if (p.action !== "leave") fail("a document nothing identifies was filed anyway");

p = plan({ filename: "Receipt_1.pdf" });
if (p.action !== "ignore") fail("business paperwork was not set aside");

p = plan({ filename: "Resume.pdf" });
if (p.action !== "note" || !p.text.startsWith("Resume on file") || p.category !== "Other") fail("a resume did not become a \"Resume on file\" note with the file");
if (p.action === "note" && (p.datedFrom !== "File date (fallback)" || !/file's saved date/.test(p.text))) fail("a note dated by the file's saved date does not say so");

// Only filename V + PDF V + on file puts a document on an authorization with
// nobody looking (punch list #1). Anything weaker is offered, not applied.
p = plan({ filename: "job coach invoice.pdf" });
if (p.action !== "propose" || p.named !== "Invoice" || p.choices.length !== 1 || p.choices[0].id !== "j" || !/a person confirms it/.test(p.why)) {
  fail(`an invoice with no V-number was put on an authorization without a person (${p.action})`);
}

p = plan({ filename: "V0000400 job coach invoice.pdf", text: "Authorization V0000400 - Job coaching 10 hrs" });
if (p.action !== "link" || p.category !== "Invoice" || p.authId !== "j" || p.start !== null) fail("an invoice whose name and PDF both show its authorization was not put on it as billed, without touching its dates");

p = plan({ filename: "V0000400 job coach invoice.pdf", text: "Job coaching 10 hrs" });
if (p.action !== "propose" || !/no V-number could be read in the PDF/.test(p.why)) fail("an invoice was filed on its name's V-number alone, with none in the PDF");

p = plan({ filename: "V0000400 job coach invoice.pdf", text: "Authorization V0000401" });
if (p.action !== "propose" || !/the PDF shows V0000401/.test(p.why)) fail("an invoice was filed although its PDF shows a different number from its name");

p = plan({ filename: "placement auth.pdf", textKind: "Other", text: "01/31/2026 Job placement 2250\nTotal 01/31/2026" });
if (p.action !== "propose" || p.named !== "Invoice" || p.choices[0]?.id !== "p") fail("a readable invoice named \"auth\" was not offered as the authorization's invoice");

p = plan({ filename: "placement auth.pdf", textKind: "Other", text: "AUTHOR1ZATI0N F0R SERV1CES garbled by a scanner 2250", ocr: { confidence: 61 } });
if (p.action !== "propose" || p.named !== "Authorization") fail("OCR text that failed to read as an authorization turned a scanned authorization into an invoice");

p = plan({ filename: "19 V0000401 PL.pdf", parsedAuth: { start: "2026-01-01", end: "2026-06-30" }, ocr: { confidence: 93 }, text: "A U T H N U M V 0 0 0 0 4 0 1\nBegin: 01/01/2026 End: 06/30/2026" });
if (p.action !== "link" || p.start !== "2026-01-01" || !p.fromOcr) fail("OCR dates were not used for a scan that shows its own authorization's number");

p = plan({ filename: "19 V0000401 PL.pdf", parsedAuth: { start: "2026-01-01", end: "2026-06-30" }, ocr: { confidence: 93 }, text: "Begin: 01/01/2026 End: 06/30/2026" });
if (p.action !== "propose" || !/no V-number could be read in the PDF/.test(p.why)) {
  fail("a scan that does not show its authorization's number was put on it without a person");
}

p = plan({ filename: "Resume.pdf", text: "Jordan Sample\nExperience\nShelving and stocking, 2019 to 2024", ocr: { confidence: 88 } });
if (p.action !== "note" || !p.fromOcr || !/Read by OCR from a scan \(Tesseract's confidence 88%\)/.test(p.text)) fail("a note made from OCR text does not say it was read by OCR");

p = plan({ filename: "Resume.pdf", text: "Jordan Sample\nExperience\nShelving and stocking, 2019 to 2024" });
if (p.action !== "note" || p.fromOcr || /Read by OCR/.test(p.text)) fail("a note from a text layer claims to be OCR");

p = plan({ filename: "placement auth.pdf", textKind: "Unreadable" });
if (p.action !== "propose" || p.named !== "Authorization" || p.choices[0]?.id !== "p") fail("a scan named \"auth\" stopped being offered as that authorization");

p = plan({ filename: "19 V0000401 PL.pdf", text: "Authorization V0000401", parsedAuth: { start: "2026-01-01", end: "2026-06-30" } });
if (p.action !== "link" || p.category !== "Authorization" || p.start !== "2026-01-01") fail("an authorization on file did not get its PDF and the dates read off it");

p = plan({ filename: "19 V0000402 JC.pdf" });
if (p.action !== "propose" || p.named !== "Authorization" || p.number !== "V0000402" || p.serviceType !== "Job Coaching") fail(`a new V-number was not proposed with its number and service (${JSON.stringify(p)})`);

p = plan({ filename: "Jordan Sample V0000403.pdf" });
if (p.action !== "propose" || p.serviceType !== null) fail("a V-number with no service code should wait with no service chosen");

p = plan({ filename: "WSA complete.pdf" });
if (p.action !== "note" || !p.restricted) fail("a completed WSA was not filed as restricted");

p = plan({ filename: "Jan [USOR96] Jordan Sample.pdf", textKind: "USOR form", textUsor: "96", fields: { MonthYear: "January 2026", Summary: "Applied to two roles" } });
if (p.action !== "note" || p.at !== "2026-01-31" || !/Covers January 2026/.test(p.text) || !/Summary: Applied to two roles/.test(p.text)) {
  fail("a monthly report's note is not dated by its month or does not carry what was filled in");
}
if (problems.length === p0) ok("the plan: warrants left alone, text decides when the name cannot, notes carry the form's answers and say where their date came from");

console.log("");
if (problems.length) {
  for (const m of problems) console.error(`  FAILED  ${m}`);
  process.exit(1);
}
console.log("--- FILENAME RULES VERIFIED ---");
