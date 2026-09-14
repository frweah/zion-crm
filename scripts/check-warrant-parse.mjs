/**
 * Warrant stubs, read.
 *
 *   node --experimental-strip-types scripts/check-warrant-parse.mjs
 *
 * Invented stubs in the shape USOR prints. No real warrant, voucher, client or
 * V-number appears here: the V-numbers start V0000.
 *
 * The parser reads and does not correct. What matters most is that it never
 * turns two different V-numbers into one, never invents an amount, and says
 * when the foot of the page could not be read.
 */
import { parseWarrantPage, linesTotal } from "../lib/warrant-parse.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const stub = `Utah State Office of Rehabilitation
Dept Voucher # Invoice #/Description Amount
630 26PR00001234567 V0000101B / 123456-A Sample-V0000101B-DOS 07/09/2025-560.00 560.00
630 26PR00001234568 V0000102 / 123457-J Doe-Smith-V0000102-450.00 $450.00
630 | 26PR00001234569 | V0000103A / 123458-K O'Neil-V0000103A-DOS
08/01/2025-1,200.00 1,200.00
Warrant No: W00012345   Date: 08/15/2025   Total: $2,210.00`;

const p = parseWarrantPage(stub);

if (p.lines.length !== 3) fail(`expected 3 lines, read ${p.lines.length}`);
else ok("three lines read, including one that wrapped onto the next row");

const [a, b, c] = p.lines;
if (!a || a.invoiceRef !== "V0000101B" || a.describedRef !== "V0000101B" || a.serviceDate !== "2025-07-09" || a.amount !== 560 || a.describedAmount !== 560 || a.voucher !== "26PR00001234567" || a.dept !== "630" || a.clientCode !== "123456" || a.clientName !== "A Sample") {
  fail(`line 1 read wrong: ${JSON.stringify(a)}`);
} else ok("a line's two V-number copies with suffix, date of service, voucher, dept and both amounts");

if (!b || b.invoiceRef !== "V0000102" || b.describedRef !== "V0000102" || b.serviceDate !== null || b.amount !== 450 || b.clientName !== "J Doe-Smith") {
  fail(`line 2 read wrong: ${JSON.stringify(b)}`);
} else ok("a base V-number with no suffix stays without one, a hyphenated surname stays whole, and no DOS is no date");

if (!c || c.invoiceRef !== "V0000103A" || c.amount !== 1200 || c.serviceDate !== "2025-08-01" || c.voucher !== "26PR00001234569") {
  fail(`line 3 read wrong: ${JSON.stringify(c)}`);
} else ok("a wrapped line and an amount with a thousands comma");

if (p.warrantNo !== "W00012345" || p.warrantDate !== "2025-08-15" || p.total !== 2210) {
  fail(`the foot read wrong: ${p.warrantNo} ${p.warrantDate} ${p.total}`);
} else if (linesTotal(p) !== 2210 || p.problems.length) {
  fail(`lines total ${linesTotal(p)}, problems ${JSON.stringify(p.problems)}`);
} else ok("warrant number, date and total from the foot, and the lines add up to it");

// The layout of a real State of Utah stub (numbers invented): a letter and a
// space in the warrant number, a dashed date, a total with asterisks, and a
// description that repeats its V-number where a DOS would go.
const real = parseWarrantPage(`STATE OF UTAH. Division of Finance
VC0000000000 PO Box 000000, Salt Lake City UT 84114
Dept __ Voucher # Invoice # / Description Amount
600 27AW00000000169 V0000663 /950001-C Name-V0000663-DOS 7/10/26-585.00 585.00
600 27AW00000000232 V0000249 /950002-R Name-V0000249-V0000249-585.00 585.00
600 27AW00000000239 V0000260 /950003-B Name-V0000260-V0000261-585.00 585.00
Date: 08-21-2026 WARRANT NO: F 00000407 Total: $1755.00** CTRL: 1062 Page 1 of 1`);
const [r1, r2, r3] = real.lines;
if (real.warrantNo !== "F00000407" || real.warrantDate !== "2026-08-21" || real.total !== 1755 || real.lines.length !== 3) {
  fail(`the real stub layout read wrong: ${real.warrantNo} ${real.warrantDate} ${real.total} ${real.lines.length} lines`);
} else if (r1.serviceDate !== "2026-07-10" || r1.describedRef !== "V0000663" || r1.voucher !== "27AW00000000169" || r1.dept !== "600") {
  fail(`a real-layout line read wrong: ${JSON.stringify(r1)}`);
} else if (r2.describedRef !== "V0000249" || r2.amount !== 585) {
  fail(`a repeated V-number in the description was not read as one agreeing copy: ${JSON.stringify(r2)}`);
} else if (r3.describedRef !== "V0000260/V0000261") {
  fail(`two different V-numbers in one description passed as one: ${r3.describedRef}`);
} else ok("the real stub layout: \"F 00000407\" is F00000407, dashed dates, repeated V-numbers read, differing ones kept apart");

// The Amount column misread, the description's amounts adding up to the total:
// the description's are used, and the page says so.
const columnMisread = parseWarrantPage(`600 27AW00000000340 V0000923 /950004-B Name-V0000923-V0000923-2250.00 2, 250.00
600 27AW00000000342 V0000963 /950005-D Name-V0000963-V0000963-1120.00 L.:12:0'.:0:0
600 27AW00000000809 V0000306A /950006-0 Name-V0000306-V0000306-450.00 450.00
Date: 08-19-2026 WARRANT NO: F 00000565 Total: $3820.00** CTRL: 1281 Page 1 of 1`);
if (columnMisread.lines.length !== 3 || columnMisread.lines.map((l) => l.amount).join() !== "2250,1120,450" || linesTotal(columnMisread) !== 3820) {
  fail(`a misread Amount column was not settled by the description and the total: ${JSON.stringify(columnMisread.lines.map((l) => [l.amount, l.describedAmount]))}`);
} else if (!columnMisread.problems.some((p) => /amount column misread on lines 1, 2/.test(p)) || columnMisread.problems.some((p) => /no amount/.test(p))) {
  fail(`the page did not say its Amount column was misread: ${JSON.stringify(columnMisread.problems)}`);
} else if (columnMisread.lines[2].invoiceRef !== "V0000306A" || columnMisread.lines[2].describedRef !== "V0000306") {
  fail("a line whose initial OCR read as 0, with its suffix only before the slash, was not read");
} else ok("a misread Amount column gives way to the description's amounts only when those add up to the total, and says so");

// Neither the column nor the description adds up: the column stands, for review.
const neither = parseWarrantPage(`600 27AW00000000343 V0000924 /950007-B Name-V0000924-V0000924-200.00 250.00
Date: 08-19-2026 WARRANT NO: F 00000566 Total: $300.00** CTRL: 1 Page 1 of 1`);
if (neither.lines[0].amount !== 250 || neither.problems.some((p) => /misread/.test(p))) {
  fail("when neither reading adds up to the total, an amount was chosen anyway");
} else ok("when neither reading adds up to the total, nothing is chosen and the page will wait for review");

// Read literally: two different numbers stay two different numbers.
const mismatch = parseWarrantPage("630 26PR00001234570 V0000104 / 123459-B Test-V0000105-10.00 10.00\nWarrant No: W00012346 Date: 08/16/2025 Total: 10.00");
const m = mismatch.lines[0];
if (!m || m.invoiceRef !== "V0000104" || m.describedRef !== "V0000105") fail(`two different V-numbers were not kept apart: ${JSON.stringify(m)}`);
else ok("two different V-number copies are read as they are, for the database to refuse");

// OCR spacing inside the number and around the slash.
const spaced = parseWarrantPage("630 26PR00001234571 V 0000106 B/123460-C Name-V0000106B-25.00 25.00\nWarrant No W00012347 Date 08/17/2025 Total 25.00");
const s = spaced.lines[0];
if (!s || s.invoiceRef !== "V0000106B" || s.describedRef !== "V0000106B" || spaced.total !== 25) fail(`OCR spacing broke the read: ${JSON.stringify(s)} total ${spaced.total}`);
else ok("spaces OCR puts inside a V-number or around the slash do not change it");

// OCR reads a zero as a letter O in one copy: the line is found, and kept as read.
const letterO = parseWarrantPage("630 26PR00001234574 V0000109A / 123463-F Name-VO000109A-DOS 08/01/2025-1,200.00 1,200.00\nWarrant No: W00012349 Date: 08/19/2025 Total: $1,200.00");
const o = letterO.lines[0];
if (!o || o.invoiceRef !== "V0000109A" || o.describedRef !== "VO000109A" || o.amount !== 1200) {
  fail(`a V-number with an O for a zero lost its line, or was corrected: ${JSON.stringify(o)}`);
} else ok("an O read for a zero keeps the line and is not corrected, so the copies disagree and a person looks");

// A payment line that cannot be read whole is kept, not dropped.
const garbled = parseWarrantPage("630 26PR00001234575 V0000110 / 123464-G Name V0000110 garbled 30.00\nWarrant No: W00012350 Date: 08/20/2025 Total: 30.00");
const g = garbled.lines[0];
if (!g || g.invoiceRef !== "V0000110" || g.describedRef !== "" || g.amount !== 30 || !garbled.problems.some((x) => /could not be read whole/.test(x))) {
  fail(`a payment line that could not be read whole was dropped or misread: ${JSON.stringify(g)}`);
} else if (parseWarrantPage("Dept Voucher # Invoice #/Description Amount").lines.length !== 0) {
  fail("the column heading row was read as a payment line");
} else ok("a payment line that cannot be read whole is kept for review, and the column headings are not a line");

// A line with no amount column, and a total the description does not add up to.
const noAmount = parseWarrantPage("630 26PR00001234572 V0000107 / 123461-D Name-V0000107-30.00\nWarrant No: W00012348 Date: 08/18/2025 Total: 40.00");
if (noAmount.lines[0]?.amount !== null || linesTotal(noAmount) !== null || !noAmount.problems.some((x) => /no amount/.test(x))) {
  fail("a line with no amount column was given one the total does not support");
} else ok("a line with no amount column, whose description does not add up to the total, has no amount and says so");

// The same line with a total that the description's amount does add up to.
const provenByTotal = parseWarrantPage("630 26PR00001234572 V0000107 / 123461-D Name-V0000107-30.00\nWarrant No: W00012348 Date: 08/18/2025 Total: 30.00");
if (provenByTotal.lines[0]?.amount !== 30 || !provenByTotal.problems.some((x) => /amount column misread/.test(x))) {
  fail("a missing amount column was not settled by the description's amount and the total");
} else ok("a missing amount column is settled by the description's amount when the total agrees, and the page says so");

// The foot unreadable.
const noFoot = parseWarrantPage("630 26PR00001234573 V0000108 / 123462-E Name-V0000108-40.00 40.00");
if (!["no warrant number read", "no warrant date read", "no total read"].every((x) => noFoot.problems.includes(x))) {
  fail(`a page with no foot did not say so: ${JSON.stringify(noFoot.problems)}`);
} else ok("a page whose foot could not be read says which parts are missing");

// Not a warrant at all.
const blank = parseWarrantPage("Scanned with a phone\nPage 2 of 3");
if (blank.lines.length !== 0 || !blank.problems.includes("no lines read")) fail("a page with no warrant lines was read as having some");
else ok("a page with no lines reads as none");

console.log("");
if (problems.length) {
  for (const x of problems) console.error(`  FAILED  ${x}`);
  process.exit(1);
}
console.log("--- WARRANT PARSING VERIFIED ---");
