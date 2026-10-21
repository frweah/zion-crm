/**
 * Store an approved terms document as a portal terms version, word for word.
 *
 *   node scripts/import-portal-terms.mjs <path-to.docx> <version> [--current]
 *
 * Writes supabase/portal-terms/<version>.json (the text, as the portal shows
 * it) and supabase/migrations/NNNN_portal_terms_<version>.sql (which stores it,
 * and makes it the version people are asked to agree to when --current).
 *
 * Nothing is reworded, trimmed or corrected. Each paragraph keeps its words
 * exactly and its role in the document - heading, list item, bold line, italic
 * note - so the portal can lay it out without changing what it says. The
 * fingerprint is of that text, so a later document with any change at all is a
 * different version, and asks everybody to consent again.
 */
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";

const [file, version, ...flags] = process.argv.slice(2);
if (!file || !version || !/^[a-z0-9][a-z0-9.-]*$/i.test(version)) {
  console.error("usage: node scripts/import-portal-terms.mjs <document.docx> <version> [--current]");
  process.exit(1);
}
const current = flags.includes("--current");

function documentXml(docx) {
  for (const [cmd, args] of [
    ["unzip", ["-p", docx, "word/document.xml"]],
    ["tar", ["-xOf", docx, "word/document.xml"]],
  ]) {
    try {
      return execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 20 * 1024 * 1024 });
    } catch {
      // try the next way of opening a zip
    }
  }
  throw new Error("Could not open the document. Is it a .docx?");
}

const decode = (s) =>
  s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");

/** One paragraph: its words, and what kind of paragraph it is. */
function readParagraph(p) {
  const style = (p.match(/<w:pStyle w:val="([^"]+)"/) || [])[1] ?? "";
  const isList = /<w:numPr>/.test(p);
  const runs = [...p.matchAll(/<w:r\b[\s\S]*?<\/w:r>/g)].map((m) => m[0]);
  let text = "";
  let allBold = runs.length > 0;
  let allItalic = runs.length > 0;
  for (const run of runs) {
    const pieces = [...run.matchAll(/<w:t(?: [^>]*)?>([^<]*)<\/w:t>|<w:tab\/>|<w:br\/>/g)];
    const runText = pieces.map((m) => (m[0].startsWith("<w:tab") ? "\t" : m[0].startsWith("<w:br") ? "\n" : decode(m[1]))).join("");
    if (!runText.trim()) continue;
    text += runText;
    const props = (run.match(/<w:rPr>[\s\S]*?<\/w:rPr>/) || [""])[0];
    if (!/<w:b\/>|<w:b w:val="(1|true)"\/>/.test(props)) allBold = false;
    if (!/<w:i\/>|<w:i w:val="(1|true)"\/>/.test(props)) allItalic = false;
  }
  if (!text.trim()) return null;
  if (/^Heading1$|^Title$/i.test(style)) return { type: "h2", text };
  if (/^Heading[2-9]$/i.test(style)) return { type: "h3", text };
  if (isList) return { type: "li", text };
  if (allBold) return { type: "strong", text };
  if (allItalic) return { type: "em", text };
  return { type: "p", text };
}

const xml = documentXml(file);
const body = xml.split("</w:p>").map(readParagraph).filter(Boolean);
if (body.length === 0) throw new Error("No text found in the document.");

// The document's own title line - the first bold line naming the portal terms.
const titleBlock = body.find((b) => b.type === "strong" && /terms/i.test(b.text));
const title = titleBlock?.text ?? "Client Portal — Terms of Use and Privacy Notice";

const canonical = body.map((b) => `${b.type}\t${b.text}`).join("\n");
const sha = createHash("sha256").update(canonical, "utf8").digest("hex");

const root = new URL("../", import.meta.url);
const termsDir = new URL("supabase/portal-terms/", root);
mkdirSync(termsDir, { recursive: true });
const json = JSON.stringify({ version, title, source_file: path.basename(file), text_sha256: sha, body }, null, 2);
writeFileSync(new URL(`${version}.json`, termsDir), json + "\n");

const migrationsDir = new URL("supabase/migrations/", root);
const next = String(
  Math.max(...readdirSync(migrationsDir).map((f) => Number(f.slice(0, 4))).filter(Number.isFinite)) + 1,
).padStart(4, "0");
const tag = "$terms$";
if (json.includes(tag)) throw new Error("The document contains the SQL quote marker; choose another.");
const sql = `-- Zion Vocational Rehab CRM — client portal terms, version ${version}
--
-- Stored word for word from ${path.basename(file)} by scripts/import-portal-terms.mjs.
-- The text of a stored version cannot change (public.portal_terms_frozen); a
-- corrected document is imported as a new version${current ? ", and making it current asks everybody to consent again" : ""}.

insert into public.portal_terms (version, title, source_file, body, text_sha256, published_at, is_current)
select v.version, v.title, v.source_file, v.body, v.text_sha256, now(), false
  from (select ${tag}${version}${tag}::text as version,
               ${tag}${title}${tag}::text as title,
               ${tag}${path.basename(file)}${tag}::text as source_file,
               ${tag}${JSON.stringify(body)}${tag}::jsonb as body,
               '${sha}'::text as text_sha256) v
 where not exists (select 1 from public.portal_terms t where t.version = v.version);
${
  current
    ? `
update public.portal_terms set is_current = false where is_current and version <> ${tag}${version}${tag};
update public.portal_terms set is_current = true where version = ${tag}${version}${tag} and not is_current;
`
    : ""
}`;
const migrationName = `${next}_portal_terms_${version.replace(/[^a-z0-9]+/gi, "_")}.sql`;
writeFileSync(new URL(migrationName, migrationsDir), sql);

console.log(`${body.length} paragraphs, fingerprint ${sha.slice(0, 16)}…`);
console.log(`wrote supabase/portal-terms/${version}.json and supabase/migrations/${migrationName}`);
for (const b of body) console.log(`  ${b.type.padEnd(6)} ${b.text.slice(0, 90)}`);
