/**
 * The five reports, checked where no database is needed (0276, 0277).
 *
 *   node scripts/check-client-reports.mjs
 *
 * The five exist in two places that have to agree: `REPORT_TEMPLATES` in
 * lib/report-shape.ts, which the screens offer, and the check constraint on
 * `client_reports.template`, which the database accepts. A template a screen
 * offers and the database refuses is a report somebody loses on save.
 *
 * And one thing only a static check can hold: a template is chosen through
 * `reportTemplateFromForm`, not read off the form. The same rule as the note
 * categories, for the same reason - a screen that trusts the form sends
 * whatever was in it.
 */
import { readFile, readdir } from "node:fs/promises";
import {
  REPORT_TEMPLATES,
  reportPeriodUnit,
  reportTemplateFromForm,
  sectionIsIn,
} from "../lib/report-shape.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const DIR = new URL("../supabase/migrations/", import.meta.url);
const names = (await readdir(DIR)).filter((n) => n.endsWith(".sql")).sort();
const files = [];
for (const name of names) files.push({ name, text: await readFile(new URL(name, DIR), "utf8") });
const newest = (re) => files.filter((f) => re.test(f.text)).at(-1) ?? null;

// ── the five in the list are the five in the constraint ──────
const migration = newest(/constraint client_reports_template\s*\n?\s*check \(template in \(/);
if (!migration) {
  fail("nothing constrains client_reports.template, so the database takes any report name");
} else {
  const block = migration.text.match(/constraint client_reports_template[\s\S]*?check \(template in \(([\s\S]*?)\)\)/);
  const inSql = [...(block?.[1] ?? "").matchAll(/'([^']+)'/g)].map((m) => m[1]);
  const listed = REPORT_TEMPLATES.map((t) => t.key);
  const missing = listed.filter((t) => !inSql.includes(t));
  const extra = inSql.filter((t) => !listed.includes(t));
  if (missing.length) {
    fail(`the screen offers ${missing.join(", ")} and the database refuses them`);
  } else if (extra.length) {
    fail(`the database accepts ${extra.join(", ")} and no screen offers them`);
  } else if (inSql.length !== 5) {
    fail(`there are ${inSql.length} report templates and the owner listed five`);
  } else {
    ok(`all ${inSql.length} report templates are offered and accepted`);
  }
}

// ── a period is a Monday or the first of a month ─────────────
// Both halves of the rule, because the constraint is a CASE and getting one
// branch right proves nothing about the other.
const starts = newest(/constraint client_reports_period_starts/);
if (!starts) {
  fail("nothing constrains what a report's period may be");
} else {
  const body = starts.text.slice(
    starts.text.indexOf("constraint client_reports_period_starts"),
  );
  if (!/isodow from period\) = 1/.test(body)) {
    fail("the weekly report's period is not held to a Monday");
  } else if (!/day from period\) = 1/.test(body)) {
    fail("the monthly reports' periods are not held to the first of a month");
  } else {
    ok("a week begins on a Monday and a month starts on the first, in the database");
  }
}

// And the two agree with the list, which is what decides which branch applies.
const weekly = REPORT_TEMPLATES.filter((t) => reportPeriodUnit(t.key) === "week").map((t) => t.key);
if (weekly.length !== 1 || weekly[0] !== "Weekly job search update") {
  fail(`the constraint singles out the weekly job search update and the list says ${weekly.join(", ") || "none"} is weekly`);
} else {
  ok("and the one weekly template is the one the constraint names");
}

// ── a template is chosen, never read off the form ────────────
const action = await readFile(
  new URL("../app/(app)/clients/[id]/reports/month-actions.ts", import.meta.url),
  "utf8",
);
if (!/reportTemplateFromForm\(/.test(action)) {
  fail("the action does not put the template through reportTemplateFromForm");
} else if (/template:\s*String\(formData\.get\("template"\)/.test(action)) {
  fail("the action writes the raw form value as the template");
} else {
  ok("a template is chosen through the rule, never read off the form");
}

// The rule itself, run rather than read.
if (reportTemplateFromForm("Monthly client report") !== "Monthly client report") {
  fail("reportTemplateFromForm refuses a template that is one of the five");
} else if (reportTemplateFromForm("Something else") !== null) {
  fail("reportTemplateFromForm accepts a template that is not one of the five");
} else if (reportTemplateFromForm(undefined) !== null) {
  fail("reportTemplateFromForm accepts nothing at all as a template");
} else {
  ok("and the rule takes the five and nothing else");
}

// ── a filtered template cannot say more than the monthly one ─
// The monthly report carries every section; the other four carry some. A
// template whose families let through a section the monthly report does not
// have would be a second account of the same month.
const monthly = REPORT_TEMPLATES.find((t) => t.key === "Monthly client report");
if (!monthly || monthly.families !== null) {
  fail("the monthly client report does not carry every section, so it is not the whole month");
} else {
  // The five families `lib/report-period.ts` knows. Asserted the other way
  // round from the first version of this, which walked these five and asked
  // whether each got through - so a template naming a family that does not
  // exist passed, because the walk never reached it. What has to be true is
  // that every family a template *names* is one of these.
  const FAMILIES = ["assessment", "development", "placement", "coaching", "life"];
  const invented = REPORT_TEMPLATES.filter((t) => t.families !== null).flatMap((t) =>
    t.families.filter((f) => !FAMILIES.includes(f)).map((f) => `${t.key} names ${f}`),
  );
  const wrong = REPORT_TEMPLATES.filter((t) => t.families !== null).filter((t) =>
    FAMILIES.some((f) => sectionIsIn(t.key, f) && !sectionIsIn("Monthly client report", f)),
  );
  if (invented.length) {
    fail(`${invented.join(", ")}, which is not a service family any section has`);
  } else if (wrong.length) {
    fail(`${wrong.map((t) => t.key).join(", ")} would carry a section the monthly report does not`);
  } else {
    ok("the four narrower reports are the monthly report with sections left out, never more");
  }
}

// ── the General section is in all five ───────────────────────
// A line the practice could not match to an authorized service still happened
// in the period, and a report that dropped it would be a report with a hole.
const dropsGeneral = REPORT_TEMPLATES.filter((t) => !sectionIsIn(t.key, null));
if (dropsGeneral.length) {
  fail(`${dropsGeneral.map((t) => t.key).join(", ")} leaves out what could not be matched to a service`);
} else {
  ok("every template carries the lines that matched no authorized service");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- CLIENT REPORTS VERIFIED ---");
