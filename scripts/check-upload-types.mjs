/**
 * A file picker never offers a type the bucket refuses.
 *
 * Found by trying it, on 14 Nov 2026. Item F added eight extensions to the
 * client record's file picker - .wav and .flac among them - and did not widen
 * the bucket that the browser uploads to. So the form offered a WAV, the
 * person chose a WAV, and storage refused it: "mime type audio/wav is not
 * supported". A handheld recorder is the obvious thing a WAV comes from, and
 * the practice had just been told it could upload one.
 *
 * The two lists had been kept in step by hand since 0009, which worked until
 * the day somebody changed one of them. 0342 widened the bucket for the
 * phone; item F widened the form and not the bucket. Nothing asked.
 *
 * ── what this asks ───────────────────────────────────────────
 *
 * Every file input that uploads straight from the browser - an `accept`
 * attribute in a file that also calls `storage.from("<bucket>")` - has every
 * mime type a browser sends for the extensions it offers granted on that
 * bucket.
 *
 * The bucket's granted types are read from the migrations rather than from the
 * database, so this runs in `prebuild` with no credentials. Buckets are
 * created with a list and widened by appending to it, so the union of every
 * `allowed_mime_types` array a migration writes for a bucket is what that
 * bucket admits. `verify_recordings.sql` asks the live database the same
 * question, which is what catches a hand-made change in the Supabase console.
 *
 * Screens that upload through a server action are not covered: their bucket is
 * named in the action, not beside the picker, and a check that went looking
 * for it in another module would be guessing. They carry small files - the
 * 4.5 MB body limit, see check-upload-limits - and are not where this bug has
 * ever bitten. A new browser upload, though, has to have both an `accept` and
 * a `from(...)` in the same file to work at all, so it is asked about from the
 * day it is written without anybody adding it to a list here.
 */
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];

/**
 * What a browser puts in `file.type` for each extension the app offers.
 *
 * Several extensions have more than one spelling, because the browser chooses
 * the string and the machine's own file-type registry is what it reads. A
 * Windows machine reports a .wav as audio/wav, audio/x-wav or audio/wave
 * depending on what is installed. Storage compares the string exactly, so
 * granting one spelling and refusing another is the same bug on a different
 * desk.
 *
 * This table is the place to add a spelling when a real refusal turns one up.
 * It holds what is known to be sent, not everything that could be: a guess
 * added here fails the build and sends somebody to write a migration for a
 * type nobody has ever uploaded.
 */
const SENT_FOR = {
  pdf: ["application/pdf"],
  jpg: ["image/jpeg"],
  jpeg: ["image/jpeg"],
  png: ["image/png"],
  heic: ["image/heic"],
  webp: ["image/webp"],
  tif: ["image/tiff"],
  tiff: ["image/tiff"],
  doc: ["application/msword"],
  docx: ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
  xls: ["application/vnd.ms-excel"],
  xlsx: ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
  txt: ["text/plain"],
  // Windows reports a .csv as Excel's type when Excel is installed, which is
  // most desks in the practice.
  csv: ["text/csv", "application/vnd.ms-excel"],
  ofx: ["application/x-ofx"],
  qfx: ["application/x-qfx"],
  // Recordings. A phone records webm/mp4/ogg; a handheld recorder or a
  // desktop dictation app writes wav, mp3 or flac.
  wav: ["audio/wav", "audio/x-wav", "audio/wave"],
  mp3: ["audio/mpeg", "audio/mp3"],
  m4a: ["audio/x-m4a", "audio/m4a", "audio/mp4"],
  mp4: ["audio/mp4"],
  ogg: ["audio/ogg"],
  webm: ["audio/webm"],
  aac: ["audio/aac"],
  flac: ["audio/flac", "audio/x-flac"],
};

/**
 * Which mime types each bucket admits, from the migrations.
 *
 * Every `allowed_mime_types` array a migration writes next to a bucket id is
 * read, and the union taken. A migration that creates the bucket and one that
 * appends to it are both just arrays of quoted strings as far as this is
 * concerned.
 */
function grantedByBucket() {
  const dir = path.join(root, "supabase", "migrations");
  const granted = new Map();
  for (const name of readdirSync(dir).sort()) {
    if (!name.endsWith(".sql")) continue;
    const sql = readFileSync(path.join(dir, name), "utf8");
    if (!sql.includes("allowed_mime_types")) continue;
    /*
     * Each statement that mentions allowed_mime_types, up to its semicolon.
     * The bucket it is about is the id named in the same statement, and the
     * types are every quoted string in it that looks like a mime type - which
     * leaves out the bucket id, the bucket name and the numbers.
     */
    for (const stmt of sql.split(";")) {
      if (!stmt.includes("allowed_mime_types")) continue;
      const ids = [...stmt.matchAll(/'([a-z-]+-files|warrants)'/g)].map((m) => m[1]);
      const types = [...stmt.matchAll(/'([a-z]+\/[a-zA-Z0-9.+-]+)'/g)].map((m) => m[1]);
      if (!ids.length || !types.length) continue;
      for (const id of new Set(ids)) {
        if (!granted.has(id)) granted.set(id, new Set());
        for (const t of types) granted.get(id).add(t);
      }
    }
  }
  return granted;
}

const granted = grantedByBucket();
if (granted.size === 0) {
  failures.push(
    "No bucket in supabase/migrations grants any mime type, which cannot be right - the way the migrations name their buckets has changed and this check is reading nothing.",
  );
}

/** Every .tsx under app/, so a new screen is asked about without being listed. */
function screens(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...screens(full));
    else if (entry.name.endsWith(".tsx")) out.push(full);
  }
  return out;
}

let asked = 0;
for (const file of screens(path.join(root, "app"))) {
  const src = readFileSync(file, "utf8");
  const accepts = [...src.matchAll(/accept="([^"]+)"/g)].map((m) => m[1]);
  if (!accepts.length) continue;

  // The bucket this screen uploads to, named beside the picker.
  const buckets = [...src.matchAll(/\.from\("([a-z-]+-files|warrants)"\)/g)].map((m) => m[1]);
  const upload = /storage\s*\n?\s*\.from\(|\.upload\(/.test(src);
  if (!buckets.length || !upload) continue;

  const where = path.relative(root, file).replaceAll("\\", "/");
  for (const bucket of new Set(buckets)) {
    const admits = granted.get(bucket);
    if (!admits) {
      failures.push(`${where} uploads to the ${bucket} bucket, which no migration grants any mime type.`);
      continue;
    }
    for (const accept of accepts) {
      for (const piece of accept.split(",").map((s) => s.trim())) {
        // A wildcard such as image/* is not a list of types and is left
        // alone: what the browser sends for it depends on what the person
        // picks, and narrowing that is a decision about the screen.
        if (!piece.startsWith(".")) continue;
        const ext = piece.slice(1).toLowerCase();
        const sent = SENT_FOR[ext];
        if (!sent) {
          failures.push(
            `${where} offers ${piece} and this check does not know what a browser sends for it - add it to SENT_FOR in scripts/check-upload-types.mjs, then make sure the ${bucket} bucket grants it.`,
          );
          continue;
        }
        asked += 1;
        for (const mime of sent) {
          if (!admits.has(mime)) {
            failures.push(
              `${where} offers ${piece}, which a browser sends as ${mime}, and the ${bucket} bucket does not grant that - the upload is refused after the person has chosen the file.`,
            );
          }
        }
      }
    }
  }
}

if (asked === 0) {
  failures.push(
    "No browser upload was found to ask about, which cannot be right - the client record, the message thread and the portal all upload straight to storage.",
  );
}

if (failures.length) {
  console.error("check-upload-types FAILED\n");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log(`check-upload-types ok — ${asked} offered file types, every one granted on the bucket it uploads to`);
