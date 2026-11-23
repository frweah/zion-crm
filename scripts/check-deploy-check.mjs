/**
 * The deploy check is runnable before it is run.
 *
 * `scripts/smoke.mjs` is a 1,900-line module whose top-level code only ever
 * executes with credentials, which means every fault in it is found on
 * production, by the run that rolls production back. On 23 November 2026 a
 * block that posts an action was added above the `const` that `actionForms`
 * reads: the call threw
 *
 *   ReferenceError: Cannot access 'unescape' before initialization
 *
 * forty seconds into the run, the job failed, and production went back to the
 * previous deployment. Nothing local caught it, because without
 * SMOKE_BASE_URL the module exits before it reaches its own first statement.
 *
 * Two questions, both answerable without credentials:
 *
 *   it parses - `node --check`, which is free and catches a stray brace in a
 *   file nothing else compiles;
 *
 *   and nothing at the top level calls a helper that reads a `const` declared
 *   further down. A function declaration is hoisted and the const it closes
 *   over is not, so the order of the statements is part of whether the check
 *   works at all.
 */
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const problems = [];
const bad = (line) => problems.push(line);
const file = new URL("../scripts/smoke.mjs", import.meta.url);
const src = readFileSync(file, "utf8");

// ── 1. it parses ──────────────────────────────────────────────
{
  const said = spawnSync(process.execPath, ["--check", "scripts/smoke.mjs"], {
    // fileURLToPath, not pathname: the path holds spaces, and a URL keeps
    // them as %20 - which is a directory that does not exist.
    cwd: fileURLToPath(new URL("../", import.meta.url)),
    encoding: "utf8",
  });
  if (said.status !== 0) {
    bad(`the deploy check does not parse: ${(said.stderr ?? "").split("\n").slice(0, 3).join(" ").trim()}`);
  }
}

// ── 2. nothing runs before what it needs ──────────────────────
/**
 * Where each top-level `const` is declared, and where each top-level function
 * is. Top level means column zero: a declaration inside a function is
 * indented, and this file indents consistently.
 */
const lines = src.split("\n");
const constAt = new Map();
const functionBodies = [];

let current = null;
for (const [i, line] of lines.entries()) {
  const named = line.match(/^const ([A-Za-z_$][\w$]*)\s*=/);
  if (named) constAt.set(named[1], i);

  const fn = line.match(/^(?:async )?function ([A-Za-z_$][\w$]*)\s*\(/);
  if (fn) {
    current = { name: fn[1], from: i, to: i, body: "" };
    functionBodies.push(current);
    continue;
  }
  // A function's body is everything until the next column-zero `}`.
  if (current) {
    if (/^\}/.test(line)) current = null;
    else {
      current.body += `${line}\n`;
      current.to = i;
    }
  }
}

/** The top-level consts a function reads, directly or through another one. */
const needs = new Map();
const reads = (fn) =>
  [...constAt.keys()].filter((name) => new RegExp(`\\b${name}\\b`).test(fn.body));
for (const fn of functionBodies) needs.set(fn.name, new Set(reads(fn)));
// One more pass, so a helper that calls a helper carries what that one needs.
for (let round = 0; round < 3; round += 1) {
  for (const fn of functionBodies) {
    for (const other of functionBodies) {
      if (other === fn) continue;
      if (new RegExp(`\\b${other.name}\\s*\\(`).test(fn.body)) {
        for (const name of needs.get(other.name) ?? []) needs.get(fn.name).add(name);
      }
    }
  }
}

/**
 * And every top-level call of one of those functions comes after the consts
 * it reads.
 *
 * A call inside another function is somebody else's problem - it runs when it
 * is called. This is only about statements the module runs on its way down.
 */
let checked = 0;
for (const [i, line] of lines.entries()) {
  if (/^\s/.test(line) || /^(?:async )?function /.test(line)) continue;
  for (const fn of functionBodies) {
    const inside = i >= fn.from && i <= fn.to;
    if (inside) continue;
    if (!new RegExp(`\\b${fn.name}\\s*\\(`).test(line)) continue;
    checked += 1;
    for (const name of needs.get(fn.name) ?? []) {
      const declared = constAt.get(name);
      if (declared !== undefined && declared > i) {
        bad(
          `line ${i + 1} calls ${fn.name}(), which reads "${name}" - and ${name} is not declared until line ${declared + 1}. ` +
            "It will throw \"Cannot access before initialization\" on the real run.",
        );
      }
    }
  }
}

if (checked === 0) {
  bad("no top-level call of a helper was found, so the order of the file was not actually checked");
}

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with the deploy check itself`);
  process.exit(1);
}
console.log(`  ok  the deploy check parses, and its ${checked} top-level calls run after what they read`);
