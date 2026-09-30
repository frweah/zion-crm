/**
 * No screen promises a bigger file than the framework will carry.
 *
 * Melanie's onboarding upload failed three times from an Android phone on 30
 * Sept 2026, and what she saw was "Application error: a server-side exception
 * has occurred". The cause was two limits that disagreed: the upload action
 * said 25 MB, and Next's server actions refuse a request body over 1 MB
 * unless told otherwise. The refusal happens before any of our code runs, so
 * nothing could catch it, log it, or say anything useful about it - the
 * screen's own "That file is over 25MB" could never have been reached.
 *
 * So: every size limit a server action enforces is compared with the body
 * limit configured in next.config.mjs. A limit somebody raises later without
 * raising the other is the same bug again, and it fails here instead of on a
 * phone.
 *
 * Routes under app/api are not server actions - they take the request
 * themselves and are not subject to that limit - so they are not counted.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];

const config = readFileSync(path.join(root, "next.config.mjs"), "utf8");
const configured = config.match(/bodySizeLimit:\s*["'](\d+(?:\.\d+)?)(mb|kb)["']/i);
if (!configured) {
  failures.push(
    "next.config.mjs sets no serverActions.bodySizeLimit, so the limit is Next's default of 1 MB - smaller than every upload the app offers.",
  );
}
const bodyLimit = configured
  ? Number(configured[1]) * (configured[2].toLowerCase() === "mb" ? 1024 * 1024 : 1024)
  : 1024 * 1024;

function walk(dir) {
  for (const entry of readdirSync(dir)) {
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) {
      if (entry === "node_modules" || entry === ".next") continue;
      walk(full);
      continue;
    }
    if (!/\.tsx?$/.test(entry)) continue;

    const rel = path.relative(root, full).split(path.sep).join("/");
    // A route handler reads the request itself; the body limit is not its rule.
    if (rel.startsWith("app/api/")) continue;

    const source = readFileSync(full, "utf8");
    // Only files that actually run as a server action.
    if (!/^\s*["']use server["']/m.test(source)) continue;

    for (const [, name, expr] of source.matchAll(
      /const\s+(MAX_[A-Z_]*BYTES)\s*=\s*([\d\s*_]+(?:\*\s*1024\s*\*\s*1024|\*\s*1024)?)\s*;/g,
    )) {
      const value = Number(new Function(`return ${expr}`)());
      if (!Number.isFinite(value)) continue;
      if (value > bodyLimit) {
        failures.push(
          `${rel} accepts files up to ${(value / (1024 * 1024)).toFixed(1)} MB (${name}), but a server action's body limit is ${(bodyLimit / (1024 * 1024)).toFixed(1)} MB. The bigger promise is the one nobody can keep.`,
        );
      }
    }
  }
}

walk(path.join(root, "app"));
walk(path.join(root, "lib"));

if (failures.length > 0) {
  console.error("");
  for (const f of failures) console.error(`  FAILED  ${f}`);
  console.error("");
  process.exit(1);
}

console.log("");
console.log(
  `  ok  every upload limit fits inside the ${(bodyLimit / (1024 * 1024)).toFixed(0)} MB a server action will carry`,
);
console.log("");
console.log("--- UPLOAD LIMITS VERIFIED ---");
