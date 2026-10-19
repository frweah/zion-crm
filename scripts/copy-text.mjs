/**
 * The words on a screen, pulled out of the source.
 *
 * Shared by scripts/check-copy.mjs and scripts/check-words.mjs so that both
 * judge the same thing. The first version of the copy check scanned the whole
 * file and reported spread operators as ellipses and non-null assertions as
 * exclamation marks, which is what happens when a prose rule is applied to
 * code.
 *
 * What counts as prose, and nothing else counts:
 *
 *   Text between tags, with no expression in it. Anything with a { } in it is
 *   assembled at runtime and what an extractor pulls out of it is a fragment
 *   of code, not a sentence.
 *
 *   The attributes that carry words to a person: placeholder, title,
 *   aria-label, and the props the house components take for them - label,
 *   note, context, empty, lead.
 *
 *   A string returned as an error or a confirmation from a server action,
 *   because that is read on a screen even though it is written in a .ts file.
 *
 * Comments are stripped first. The house style is long comments explaining
 * why, and judging those by the rules for a button is nonsense.
 */
import { readdir, readFile } from "node:fs/promises";

/* Each piece of prose comes back as { path, text, line }, so a failure can
   name where it is. */

const PROJECT = new URL("../", import.meta.url).pathname;

export const rel = (url) => {
  const p = decodeURIComponent(url.pathname);
  const root = decodeURIComponent(PROJECT);
  return p.startsWith(root) ? p.slice(root.length) : p;
};

export async function sourceFiles(dir, extensions = [".tsx"]) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const url = new URL(entry.name + (entry.isDirectory() ? "/" : ""), dir);
    if (entry.isDirectory()) out.push(...(await sourceFiles(url, extensions)));
    else if (extensions.some((e) => entry.name.endsWith(e))) out.push(url);
  }
  return out;
}

/** Comments out, so prose about the code is not read as prose on a screen. */
export function withoutComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " ")).replace(/^\s*\/\/.*$/gm, "");
}

const lineOf = (src, index) => src.slice(0, index).split("\n").length;

const tidy = (raw) =>
  raw
    .replace(/&apos;|&rsquo;/g, "'")
    .replace(/&quot;|&ldquo;|&rdquo;/g, '"')
    .replace(/&amp;/g, "&")
    .replace(/&mdash;/g, "—")
    .replace(/\s+/g, " ")
    .trim();

/** The attributes and props that carry words to a person. */
const COPY_ATTRS = ["placeholder", "title", "aria-label", "label", "note", "context", "empty", "lead"];

export function* prose(src, path) {
  const clean = withoutComments(src);

  /*
   * Text between tags, with no expression in it.
   *
   * The ">" that opens this is not always the end of a tag: it is also the
   * end of a generic, so `useState<string | null>(null); const [x` matched
   * and the check reported a spread operator as an ellipsis and a non-null
   * assertion as an exclamation mark. Anything carrying the punctuation of
   * code is therefore thrown away before it is read as a sentence - tested
   * on the raw text, before &amp; becomes & and starts looking like one.
   */
  // Only where there is JSX. In a .ts file every ">...<" is a generic.
  for (const m of (path.endsWith(".tsx") ? clean.matchAll(/>([^<>{}]+)</g) : [])) {
    const raw = m[1];
    const bare = raw.replace(/&(?:amp|apos|quot|rsquo|ldquo|rdquo|mdash|nbsp);/g, "");
    // The punctuation of code: assignment, arrays, logic, template literals.
    if (/[;=[\]|&`]|=>/.test(bare)) continue;
    // And the shape of a ternary between two tags - ") : !open ? (" - which
    // carries none of the above and was read as prose with an exclamation
    // mark in it.
    if (/![A-Za-z_$]/.test(bare)) continue;
    if (/^\s*\)/.test(bare) || /\?\s*\(\s*$/.test(bare)) continue;
    const text = tidy(raw);
    // At least two letters together, or it is punctuation and spacing.
    if (!/[A-Za-z]{2}/.test(text)) continue;
    yield { path, text, line: lineOf(clean, m.index) };
  }

  // The attributes that carry words.
  for (const attr of COPY_ATTRS) {
    const re = new RegExp(`\\b${attr}="([^"{}]+)"`, "g");
    for (const m of clean.matchAll(re)) {
      const text = tidy(m[1]);
      if (!/[A-Za-z]{2}/.test(text)) continue;
      yield { path, text, line: lineOf(clean, m.index) };
    }
  }

  // The same props written in an object, as the table and nav rows are.
  for (const m of clean.matchAll(/\b(?:label|note|empty|context|lead):\s*"([^"]+)"/g)) {
    const text = tidy(m[1]);
    if (!/[A-Za-z]{2}/.test(text)) continue;
    yield { path, text, line: lineOf(clean, m.index) };
  }

  // What a server action says back: read on a screen, written in a .ts file.
  for (const m of clean.matchAll(/\b(?:error|ok):\s*(?:`([^`${}]+)`|"([^"]+)")/g)) {
    const text = tidy(m[1] ?? m[2] ?? "");
    if (!/[A-Za-z]{2}/.test(text)) continue;
    yield { path, text, line: lineOf(clean, m.index) };
  }

  // And what the database is told to say, which reaches the same screens.
  for (const m of clean.matchAll(/raise exception\s+'([^']+)'/g)) {
    const text = tidy(m[1]);
    if (!/[A-Za-z]{2}/.test(text)) continue;
    yield { path, text, line: lineOf(clean, m.index) };
  }
}

export { readFile };
