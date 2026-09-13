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
} else if (fileRoute.indexOf('rpc("match_inbox_folder"') > fileRoute.indexOf("const reading = await readDocument(bytes, supabase, clientId)")) {
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

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- AGENT ROUTES VERIFIED ---");
