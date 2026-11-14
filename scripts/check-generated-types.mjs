/**
 * The generated types are what the generator generates.
 *
 *   node --env-file=.env.local scripts/check-generated-types.mjs
 *
 * `lib/database.types.ts` and `lib/rls-writes.json` are written by
 * `scripts/gen-types.mjs`, which types the functions on a **curated list** -
 * trigger functions and internal helpers are not part of the client API and
 * are deliberately left out.
 *
 * On 14 November 2026 three functions the phone app calls - `phone_clock`,
 * `phone_post_message`, `phone_to_file_confirm` - were in the generated file
 * and **not** on that list. Nobody had regenerated since they were added, so
 * nothing had noticed. The next person to run the generator dropped all three
 * and broke a build that had been green for three days, on a file nobody had
 * touched.
 *
 * A generated file that disagrees with its generator is a trap: it works
 * until somebody regenerates, and then it is their change that appears to
 * have broken it. So this runs the generator and asserts it changes nothing.
 *
 * It cannot run in prebuild - the generator reads the live schema, and
 * prebuild runs on Vercel where there are no database credentials - so it is
 * in `check-checks`'s list of checks that cannot, with that reason, and it is
 * run by hand whenever the schema changes. Which is every local build where
 * it matters.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const FILES = ["lib/database.types.ts", "lib/rls-writes.json"];
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);

const before = Object.fromEntries(FILES.map((f) => [f, readFileSync(f, "utf8")]));

try {
  execFileSync(process.execPath, ["scripts/gen-types.mjs"], {
    stdio: "pipe",
    env: process.env,
  });
} catch (err) {
  console.error(`  FAILED  the generator would not run: ${err.message.split("\n")[0]}`);
  process.exit(1);
}

for (const file of FILES) {
  const after = readFileSync(file, "utf8");
  if (after === before[file]) {
    ok(`${file} is what the generator generates`);
    continue;
  }

  // Put it back the way it was found, whichever way the difference goes: a
  // check does not leave the tree changed.
  writeFileSync(file, before[file]);

  const names = (s) => new Set([...s.matchAll(/^ {6}([a-z0-9_]+): \{$/gm)].map((m) => m[1]));
  const was = names(before[file]);
  const now = names(after);
  const dropped = [...was].filter((n) => !now.has(n));
  const gained = [...now].filter((n) => !was.has(n));

  const detail = [
    dropped.length
      ? `regenerating would drop ${dropped.join(", ")} — ${
          dropped.length === 1 ? "it is" : "they are"
        } in the file and not on the generator's list`
      : "",
    gained.length ? `regenerating would add ${gained.join(", ")}` : "",
  ]
    .filter(Boolean)
    .join("; ");

  problems.push(
    `${file} is not what the generator generates${detail ? ` — ${detail}` : ""}. ` +
      "Run node --env-file=.env.local scripts/gen-types.mjs and commit the result.",
  );
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- GENERATED TYPES VERIFIED ---");
