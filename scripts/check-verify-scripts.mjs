/**
 * A verification script may not be able to commit.
 *
 * Every one of them builds fixtures - ZZ clients, ZQ counselors, a staff row
 * with a login - against whatever database it is pointed at, which in practice
 * is production. The only thing standing between that and a test client in
 * somebody's directory is the `rollback` at the bottom of the file, and that is
 * a line a person has to remember to write.
 *
 * So it is checked instead of remembered: a script that writes must open its
 * transaction, close it with a rollback, and never commit. A read-only script
 * needs none of that and is left alone.
 *
 * The companion to this is supabase/verify_zz_no_fixtures.sql, which runs last
 * in the suite and asserts that nothing fixture-shaped is actually there - this
 * one stops a leak being written, that one catches a leak from anywhere else.
 */
import { readdir, readFile } from "node:fs/promises";

const DIR = new URL("../supabase/", import.meta.url);
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);

const WRITES = /^\s*(insert\s+into|update\s+|delete\s+from|perform\s+public\.(add_authorization|confirm_authorization|grant_staff_access))/im;

let checked = 0;
let readOnly = 0;
for (const name of (await readdir(DIR)).filter((n) => /^verify_.*\.sql$/.test(n))) {
  const text = await readFile(new URL(name, DIR), "utf8");
  const body = text.replace(/\r\n/g, "\n");

  if (!WRITES.test(body)) {
    readOnly += 1;
    // A read-only script that opens a transaction is not wrong, but it must
    // still not commit one.
    if (/^\s*commit;/im.test(body)) problems.push(`${name} commits`);
    continue;
  }

  checked += 1;
  const begins = (body.match(/^begin;/gm) ?? []).length;
  const rollbacks = (body.match(/^rollback;/gm) ?? []).length;
  if (begins !== 1) problems.push(`${name} writes and has ${begins} "begin;" of its own, expected 1`);
  if (rollbacks !== 1) problems.push(`${name} writes and has ${rollbacks} "rollback;", expected 1`);
  if (/^\s*commit;/im.test(body)) problems.push(`${name} writes and commits`);

  // The rollback has to be the last thing that happens, or whatever follows it
  // runs outside the transaction and keeps what it writes.
  const after = body.slice(body.lastIndexOf("\nrollback;") + 1).replace(/^rollback;/, "").trim();
  if (after && !/^(--|\/\*)/.test(after)) {
    problems.push(`${name} has statements after its rollback: ${after.split("\n")[0].slice(0, 50)}`);
  }
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
ok(`all ${checked} verification scripts that write roll back, and none commits`);
ok(`${readOnly} read-only script(s) need no transaction`);
console.log("");
console.log("--- VERIFICATION SCRIPTS VERIFIED ---");
