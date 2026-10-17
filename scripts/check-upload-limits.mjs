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
 * And with the limit that cannot be configured at all. The stress test on
 * 16 Oct 2026 found the same failure still live on the staff and onboarding
 * uploads, and the reason the first fix did not reach them is that
 * bodySizeLimit was never the real ceiling: Vercel refuses a request body
 * over 4.5 MB in its own infrastructure, and no Next setting raises it.
 * bodySizeLimit: "25mb" was a promise the platform had never agreed to.
 *
 * So the comparison is against whichever is smaller - what we configured and
 * what the platform allows. A screen that wants to carry more than that does
 * not raise a number; it stops sending the bytes through a server action and
 * uploads from the browser to storage instead, as the client record and the
 * staff file both now do.
 *
 * Routes under app/api are not server actions - they take the request
 * themselves - but they are served by the same infrastructure, so the 4.5 MB
 * applies to them too. They are still not counted here, because several of
 * them are agent endpoints that stream rather than take a body.
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

/**
 * What the platform allows, whatever we configure.
 *
 * Vercel's own documentation gives 4.5 MB for a request body to a function,
 * for Server Actions and Route Handlers alike, and says it cannot be raised.
 */
const PLATFORM_LIMIT = 4.5 * 1024 * 1024;
const ceiling = Math.min(bodyLimit, PLATFORM_LIMIT);

if (bodyLimit > PLATFORM_LIMIT) {
  failures.push(
    `next.config.mjs sets serverActions.bodySizeLimit to ${(bodyLimit / (1024 * 1024)).toFixed(1)} MB, ` +
      `which is more than the ${(PLATFORM_LIMIT / (1024 * 1024)).toFixed(1)} MB the platform will carry. ` +
      `A body over that is refused before any of our code runs, so the setting reads as a promise nobody keeps.`,
  );
}

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
      // Headroom, not equality. A multipart body is bigger than the file it
      // carries - boundaries, headers, the other fields - so a promise that
      // exactly equals the ceiling is still refused. 90% leaves room for an
      // envelope without inviting anybody to cut it fine.
      if (value > ceiling * 0.9) {
        failures.push(
          `${rel} accepts files up to ${(value / (1024 * 1024)).toFixed(1)} MB (${name}), ` +
            `but a server action can carry ${(ceiling / (1024 * 1024)).toFixed(1)} MB and the body is bigger than the file inside it. ` +
            `Upload from the browser to storage instead, as app/(app)/staff-file-upload.ts does.`,
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
