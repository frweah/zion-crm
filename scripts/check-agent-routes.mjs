/**
 * The document agent's server side, checked where it can be without a server.
 *
 *   node --experimental-strip-types scripts/check-agent-routes.mjs
 *
 * Two silent failures in the first real backfill are why this exists.
 *
 *   pdf.js's worker was located at runtime from a specifier assembled so the
 *   bundler would ignore it, which also meant the deployment never included
 *   the file. Every read on Vercel threw, and readable authorizations and USOR
 *   forms were filed as scans. Nothing failed locally, where node_modules is
 *   all there — so no local test of the classifier could ever have caught it.
 *
 *   Vercel refuses a request body over 4.5 MB before the application sees it,
 *   so a large scan could never arrive however generous the route's own limit
 *   was. The agent got a 413 and the CRM's logs showed nothing at all.
 *
 * Both are properties of how the code is put together rather than of what it
 * computes, so this reads the sources for the shape that keeps each one fixed.
 */
import { readFileSync } from "node:fs";
import {
  INBOX_BUCKET,
  STORAGE_MAX_BYTES,
  inboxStoragePath,
  isSha256,
} from "../lib/inbox-storage.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const src = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const pdfText = src("lib/pdf-text.ts");
const fileRoute = src("app/api/agent/file/route.ts");
const uploadRoute = src("app/api/agent/upload-url/route.ts");
const agent = src("agent/zion-agent.ps1");

// ── pdf.js's worker ships with the deployment ────────────────
if (!pdfText.includes('await import("pdfjs-dist/legacy/build/pdf.worker.mjs")')) {
  fail(
    "lib/pdf-text.ts no longer imports the pdf.js worker with a literal specifier, so the deployment will not include it",
  );
} else if (!/pdfjsWorker\s*=/.test(pdfText)) {
  fail("the pdf.js worker is imported but never handed to pdf.js as globalThis.pdfjsWorker");
} else {
  ok("the pdf.js worker is a literal import handed over as globalThis.pdfjsWorker, so it ships");
}

if (/workerSrc\s*=/.test(pdfText)) {
  fail("lib/pdf-text.ts points pdf.js at a worker file on disk again, and that path does not exist on Vercel");
} else {
  ok("nothing points pdf.js at a worker file on disk");
}

if (/pathToFileURL/.test(pdfText)) {
  fail("lib/pdf-text.ts passes a file:// URL again; pdf.js reads fonts with fs, which cannot open one");
} else {
  ok("fonts are given as a plain path, not a file:// URL");
}

// ── nothing optional can stop a read ─────────────────────────
// After the worker was fixed, resolving pdfjs-dist/package.json to find the
// font directory threw on Vercel - that file is not in the deployment - and
// every read still failed. Fonts are optional; finding them must not be fatal.
const fontBlock = pdfText.slice(pdfText.indexOf("let fontDir"), pdfText.indexOf("pdfjs.getDocument("));
if (!fontBlock || !/try\s*\{/.test(fontBlock) || !/catch/.test(fontBlock)) {
  fail("locating pdf.js's fonts can throw and stop the whole read, as it did on Vercel");
} else {
  ok("locating pdf.js's fonts is best effort and can never stop a read");
}

// ── a read error is not a reading ────────────────────────────
if (!/earlierReason\.startsWith\("could not be read:"\)/.test(fileRoute)) {
  fail("a document filed after a read error can never be read again once the error is recorded");
} else {
  ok("a document that failed to read, filed or not, can be read again; a real scan keeps its finding");
}

// ── the bytes survive being read ─────────────────────────────
// pdf.js transfers the buffer it is given, emptying the caller's array. The
// route read each PDF, then uploaded and measured the emptied bytes: 679
// documents were stored as empty files and recorded as 0 bytes.
if (!/data: bytes\.slice\(\)/.test(pdfText)) {
  fail("pdf.js is handed the caller's bytes, which it empties by transferring them");
} else {
  ok("pdf.js reads a copy, so the bytes stored are the bytes that arrived");
}
if (!/const size = bytes\.byteLength/.test(fileRoute) || !/size_bytes: size,/.test(fileRoute) || !/bytes\.byteLength !== size/.test(fileRoute)) {
  fail("the route measures or stores the bytes after reading them, when they may have been emptied");
} else {
  ok("the route records the size it received and refuses to store bytes that changed while being read");
}

// ── one place names where a document is kept ─────────────────
const hash = "ab".repeat(32);
if (!isSha256(hash) || isSha256(hash.toUpperCase()) || isSha256("ab") || isSha256(`${hash}0`)) {
  fail("isSha256 accepts something that is not a lowercase 64-character hex hash, or refuses one that is");
} else {
  ok("a document is named by exactly a lowercase SHA-256 hash");
}

if (inboxStoragePath(hash) !== `inbox/ab/${hash}.pdf` || INBOX_BUCKET !== "client-files") {
  fail(`documents are kept somewhere unexpected: ${INBOX_BUCKET}/${inboxStoragePath(hash)}`);
} else {
  ok("a document is kept at inbox/<first two>/<hash>.pdf in client-files");
}

for (const [name, text] of [
  ["the file route", fileRoute],
  ["the upload-url route", uploadRoute],
]) {
  if (!text.includes("inboxStoragePath(") || !text.includes("INBOX_BUCKET")) {
    fail(`${name} does not use the shared storage path, so an upload and a read could name different places`);
  } else if (/`inbox\//.test(text) || /"client-files"/.test(text)) {
    fail(`${name} spells out its own storage path or bucket instead of using lib/inbox-storage`);
  }
}
if (!problems.some((p) => p.includes("route"))) {
  ok("both agent routes name the storage path and bucket from one place");
}

// ── an empty file is not a document ──────────────────────────
// The first backfill met a 0-byte "PDF". The CRM refuses it, and without this
// the agent would fail on it every fifteen minutes, forever.
if (!agent.includes("$f.Length -eq 0") || !agent.includes("Empty file, not sent")) {
  fail("the agent sends empty files, which the CRM refuses on every run");
} else {
  ok("an empty file is skipped with a log line, not retried every run");
}
// ── large files go around Vercel's limit ─────────────────────
const direct = agent.match(/\$DirectLimit\s*=\s*(\d+)MB/);
const storage = agent.match(/\$StorageLimit\s*=\s*(\d+)MB/);
if (!direct || Number(direct[1]) * 1024 * 1024 >= 4.5 * 1024 * 1024) {
  fail("the agent would send a file in the request body at or over Vercel's 4.5 MB limit");
} else {
  ok(`the agent sends anything over ${direct[1]} MB straight to storage, under Vercel's 4.5 MB request limit`);
}

if (!storage || Number(storage[1]) * 1024 * 1024 !== STORAGE_MAX_BYTES) {
  fail("the agent's idea of the storage limit and the server's have drifted apart");
} else {
  ok(`the agent and the server agree on the ${STORAGE_MAX_BYTES / (1024 * 1024)} MB storage limit`);
}

if (!agent.includes("/api/agent/upload-url") || !/stored\s*=\s*'1'/.test(agent)) {
  fail("the agent no longer uses the upload-url route and stored=1 for large files");
} else {
  ok("the agent asks for an upload address, uploads, then tells the CRM the file is stored");
}

if (!/size\s*>\s*STORAGE_MAX_BYTES/.test(uploadRoute) || !uploadRoute.includes("status: 413")) {
  fail("the upload-url route no longer refuses a file over the storage limit");
} else if (uploadRoute.indexOf('.eq("sha256", hash)') > uploadRoute.indexOf("createSignedUploadUrl(")) {
  fail("the upload-url route hands out an address before checking whether the document is already held");
} else {
  ok("an upload address is refused over the limit, and never issued for a document already held");
}

// ── a stored file is not trusted ─────────────────────────────
if (!/\(claimedHash \|\| stored \|\| reprocess\) && claimedHash !== actual/.test(fileRoute)) {
  fail("the file route no longer re-checks the hash of a file read back from storage");
} else {
  ok("a file read back from storage is hashed again, so bytes that are not the named file are refused");
}

// ── reading again never overrides a decision ─────────────────
const reprocessBlock = fileRoute.slice(fileRoute.indexOf("if (reprocess) {"), fileRoute.indexOf("// Seen already"));
const rereadUpdate = reprocessBlock.match(/\.update\(\{([^}]*)\}\)/);
if (!rereadUpdate || /\b(state|decided_by|decided_at|outcome)\b/.test(rereadUpdate[1])) {
  fail("reading a document again can change what somebody decided about it");
} else if (!/existing\.state !== "Pending" && !unread/.test(reprocessBlock)) {
  fail("a decided document can be read again even when the reading it had was a real one");
} else if (!/\.eq\("state", existing\.state\)/.test(reprocessBlock)) {
  fail("reading again does not check that the decision is unchanged since it was looked at");
} else {
  ok("reading again replaces only the reading, never a decision, and a decided document only if the broken server read it");
}

// ── an authorization is matched to the ones on file ──────────
if (!fileRoute.includes("authorizationsMentioned(")) {
  fail("an authorization is no longer checked against that client's authorizations on file");
} else if (fileRoute.indexOf('rpc("match_inbox_folder"') > fileRoute.indexOf("const reading = await readDocument(bytes, supabase, clientId,")) {
  fail("a new document is read before its client is known, so it cannot be matched to their authorizations");
} else {
  ok("an authorization is matched against the numbers already on file for its client");
}

// ── an "Unreadable" says why ─────────────────────────────────
if (!/parsed = \{ reason: classification\.reason \}/.test(fileRoute)) {
  fail("an Unreadable document no longer records why, which is what hid the missing worker");
} else {
  ok("an Unreadable document keeps the reason, so a wrong one leads to its cause");
}

// ── every arrival is filed by its name ───────────────────────
// Filing by name (lib/file-by-name) runs after the document is stored and
// recorded, never before: a filing that fails must leave the document waiting,
// not lose it. And refiling reads a stored document for its text only - it is
// not a back door to replacing the recorded reading.
const insertAt = fileRoute.indexOf('.from("inbox_documents")\n    .insert(');
const arrivalFiling = fileRoute.indexOf("await fileArrival(supabase, row, reading)");
const refileBlock = fileRoute.match(/if \(refile\) \{([\s\S]*?)\n  \}/);
if (arrivalFiling < 0 || insertAt < 0 || arrivalFiling < insertAt) {
  fail("a new arrival is no longer filed by its name after it is recorded");
} else if (!/try \{[\s\S]*fileByName\([\s\S]*catch/.test(fileRoute)) {
  fail("a filing that throws could fail the arrival instead of leaving the document waiting");
} else if (!refileBlock || /\.update\(/.test(refileBlock[1])) {
  fail("refiling changes the recorded reading, which only reprocess may do");
} else {
  ok("every arrival is filed by its name once recorded, a failed filing leaves it waiting, and refiling never rewrites the reading");
}

// ── OCR ──────────────────────────────────────────────────────
// OCR text is only ever the reading of a PDF with no text layer, is kept apart
// and marked, and the agent reads scans on this machine with nothing left behind.
{
  const fs = await import("node:fs");
  const read = (rel) => fs.readFileSync(new URL(rel, import.meta.url), "utf8");
  const ocrWanted = read("../app/api/agent/ocr-wanted/route.ts");
  const ocrModule = read("../agent/zion-ocr.ps1");

  if (!fileRoute.includes('const fromOcr = !readError && Boolean(ocr?.text.trim()) && text.replace(/\\s/g, "").length < 40;')) {
    fail("OCR text can be read in place of a text layer, or for a PDF the server could not open");
  } else if (!/\.\.\.\(reading\.ocr && ocrPayload/.test(fileRoute) || !/if \(!reading\.ocr && reading\.kind !== "Unreadable"\)/.test(fileRoute)) {
    fail("OCR text is kept for a document that has text of its own");
  } else if (!/text_source: "OCR"/.test(fileRoute)) {
    fail("a reading made from OCR text is not marked as OCR");
  } else {
    ok("OCR is read only for a PDF with no text layer, kept only then, and marked as OCR");
  }

  if (!/x-zion-agent/.test(ocrWanted) || !/status: 401/.test(ocrWanted) || !/\.is\("ocr_at", null\)/.test(ocrWanted)) {
    fail("the OCR request list is open without the agent secret, or asks again for scans already read");
  } else {
    ok("only the agent can ask which scans to read, and a scan once read is not asked for again");
  }

  if (!agent.includes("Test-PdfHasTextLayer") || !agent.includes("/api/agent/ocr-wanted") || !agent.includes("ocr_text_b64")) {
    fail("the agent no longer reads scans before sending them, or no longer answers the CRM's requests for OCR");
  } else if (!/finally\s*\{\s*Remove-Item -LiteralPath \$work -Recurse -Force/.test(ocrModule) || !/\$env:TEMP/.test(ocrModule)) {
    fail("OCR page images are not kept to their own folder under %TEMP% and removed afterwards");
  } else if (/Invoke-(RestMethod|WebRequest)/.test(ocrModule)) {
    fail("the OCR module talks to the network; it must only read files and run Tesseract");
  } else if (!/\$null = \$proc\.Handle/.test(ocrModule) || !/\$proc\.WaitForExit\(\)\s*\n\s*if \(\$proc\.ExitCode -ne 0\)/.test(ocrModule)) {
    // Agent 1.1.0: without the handle, PowerShell 5.1 reports an empty exit
    // code after a timed wait, and every page Tesseract read was a "failure".
    fail("Tesseract's exit code is read without holding the process handle, so every page reads as a failure");
  } else if (/function Write-Log[\s\S]{0,400}?Write-Output/.test(agent)) {
    // Agent 1.1.1: a log line written to the output stream became part of
    // Get-Ocr's return value, so a failed read looked like a reading.
    fail("the agent logs to the output stream, so a log line inside a function becomes part of what it returns");
  } else if (!/\$read = Get-Ocr \$local\.full\s*\n\s*if \(-not \$read\) \{[^}]*\bcontinue\s*\}/.test(agent) || !/if \(\$late\) \{/.test(agent)) {
    // Agent 1.1.0 sent a failed read as "nothing readable", and the CRM
    // stopped asking for those scans.
    fail("a failed OCR is reported to the CRM as an empty reading, which stops it being asked for again");
  } else {
    ok("the agent reads scans locally before sending, answers the CRM's requests, and leaves no page images behind");
  }
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- AGENT ROUTES VERIFIED ---");
