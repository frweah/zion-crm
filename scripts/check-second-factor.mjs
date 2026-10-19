/**
 * The second-factor screen tells the person what happened (0217).
 *
 *   node scripts/check-second-factor.mjs   (also runs before every `npm run build`)
 *
 * On 19 Oct enrolling a second factor looked like it did nothing: scan the QR,
 * type the code, and the screen came back asking for a code. The database was
 * right the whole time. The factor was saved, verified, and the Admin roster
 * showed it. Every one of the four things worth suspecting - whether TOTP was
 * enabled, whether verify was erroring, whether the challenge had expired,
 * whether the factor was being saved - was fine.
 *
 * The screen was wrong, in three ways that each look like silence:
 *
 *   1. No state for having succeeded. A good code cleared the form and fell
 *      through to the branch that asks for a code, so the person gave another
 *      one, successfully, forever.
 *
 *   2. Nothing caught. An error thrown rather than handed back in the result
 *      skipped the line that stops the spinner and showed no message, so the
 *      button sat reading "Checking..." with no reason given.
 *
 *   3. The code form answered the challenge on the first factor on the
 *      account. An abandoned attempt leaves an unverified one, whose secret
 *      nobody ever scanned, so every code after that is wrong.
 *
 * So this does not ask whether the screen looks reasonable. It asks the three
 * questions the bug actually turned on, because a check written near a rule
 * passes the bug it was written for.
 */
import { sourceFiles, rel, readFile, withoutComments } from "./copy-text.mjs";

const SECURITY = new URL("../app/(app)/security/", import.meta.url);
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

/**
 * The brace depths of the `try` blocks open at each point in the source.
 *
 * Comments are stripped first, so the braces counted are the code's own. A
 * template literal contributes a matched pair, which leaves the depth right.
 */
function tryDepths(src) {
  const spans = [];
  const open = [];
  let depth = 0;
  let pendingTry = false;

  for (let i = 0; i < src.length; i++) {
    if (src.startsWith("try", i) && /^\s*\{/.test(src.slice(i + 3))) pendingTry = true;
    const c = src[i];
    if (c === "{") {
      depth++;
      if (pendingTry) {
        open.push(depth);
        pendingTry = false;
      }
    } else if (c === "}") {
      if (open.length > 0 && open[open.length - 1] === depth) open.pop();
      depth--;
    }
    spans[i] = open.length;
  }
  return spans;
}

/** Where the block containing `from` closes. */
function blockEnd(src, from) {
  let depth = 0;
  for (let i = from; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      if (depth === 0) return i;
      depth--;
    }
  }
  return src.length;
}

let callsSeen = 0;
let screensSeen = 0;

for (const url of await sourceFiles(SECURITY, [".tsx", ".ts"])) {
  const path = rel(url);
  const raw = await readFile(url, "utf8");
  const src = withoutComments(raw);
  const lineAt = (i) => src.slice(0, i).split("\n").length;

  const calls = [...src.matchAll(/supabase\.auth\.mfa\.(\w+)/g)];
  if (calls.length === 0) continue;
  screensSeen++;

  // 2. Nothing that talks to the authenticator is left uncaught.
  const inTry = tryDepths(src);
  for (const m of calls) {
    callsSeen++;
    if (inTry[m.index] === 0) {
      fail(
        `${path}:${lineAt(m.index)} calls ${m[0]} outside a try. ` +
          `An error thrown rather than returned shows the person nothing at all.`,
      );
    }
  }

  // 1. A screen that confirms something has a state for having confirmed it.
  //
  //    Asking whether the file has such a state anywhere is the mistake that
  //    lets this bug back in: the broken version had `enrolling`, which is set
  //    to something and branched on, and it would have passed. So the question
  //    is narrower - on the path taken when the code was *right*, is anything
  //    set to something, or is the form only cleared? Clearing is what dropped
  //    the person back to the screen that asked for a code.
  for (const m of src.matchAll(/challengeAndVerify|mfa\.verify\(/g)) {
    // Only as far as the block the call sits in, or the overrun reads the
    // render branches below and finds an acknowledgement that is not one.
    const block = src.slice(m.index, blockEnd(src, m.index));
    // And only past the last early return, which is where the error paths
    // leave off and the path taken by a good code begins. Without this the
    // message set for a *wrong* code counts as saying the right one worked.
    const lastReturn = block.lastIndexOf("return;");
    const tail = lastReturn === -1 ? block : block.slice(lastReturn);
    const sets = [...tail.matchAll(/\bset([A-Z]\w*)\(\s*([^),\n]*)/g)];
    const acknowledges = sets.some(([, written, arg]) => {
      const read = written[0].toLowerCase() + written.slice(1);
      // Set to something, rather than cleared.
      if (/^(null|false|undefined|""|''|``|0)?$/.test(arg.trim())) return false;
      // And read when the screen decides what to render.
      return new RegExp(`(if \\(|\\{\\s*)${read}[\\s)&=]`).test(src);
    });
    if (!acknowledges) {
      fail(
        `${path}:${lineAt(m.index)} checks a code and, when it is right, only clears the form. ` +
          `Nothing is set for the screen to render as success, so the person lands back on ` +
          `the branch asking for a code - which is what a working enrolment looked like on 19 Oct.`,
      );
    }
  }

  // 3. A factor is chosen by being verified, never by being first.
  for (const m of src.matchAll(/listFactors[\s\S]{0,400}?/g)) {
    const after = src.slice(m.index, m.index + 400);
    if (/\btotp\s*(\?\.)?\[\s*0\s*\]/.test(after)) {
      fail(
        `${path}:${lineAt(m.index)} answers the challenge on the first factor listed. ` +
          `An abandoned attempt leaves an unverified one; pick the verified factor.`,
      );
    }
  }
}

if (screensSeen === 0) {
  fail("no screen under app/(app)/security/ talks to the authenticator any more. Has it moved?");
}

// The screen cannot tell "still owes us a code" from "already through" unless
// the session's assurance level reaches it. Without that it asks either
// nobody or everybody, forever.
const page = await readFile(new URL("two-factor/page.tsx", SECURITY), "utf8");
if (!/getClaims\(\)/.test(page) || !/stepped=\{/.test(page)) {
  fail(
    "app/(app)/security/two-factor/page.tsx no longer reads the session assurance level " +
      "and passes it to Enrol. Without it the screen asks an enrolled person for a code " +
      "they have already given.",
  );
}

if (problems.length === 0) {
  ok(`all ${callsSeen} authenticator calls across ${screensSeen} screen(s) report what happened`);
  ok("the screen knows whether this session has used the second factor");
  console.log("");
  console.log("--- SECOND FACTOR VERIFIED ---");
} else {
  console.error("");
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error("");
  process.exit(1);
}
