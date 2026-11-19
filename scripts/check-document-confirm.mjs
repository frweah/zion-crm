/**
 * A queued PDF is confirmed with a client and a service, and nothing waits on
 * somebody else.
 *
 *   node scripts/check-document-confirm.mjs
 *
 * Billing › Authorizations › From the documents folder used to answer a PDF
 * whose folder was not a client with "Once the administrator has said whose it
 * is, it can be confirmed here" - a person holding the document, able to read
 * the name off it, and able to do nothing. `assign_document_to_client` has
 * allowed Billing since it was written; only the screen did not.
 *
 * And Confirm went through with the service still saying "Choose…", so the
 * answer came back from the database - "A new authorization needs its service"
 * - after the press rather than before it.
 *
 * What it asks:
 *
 *   1. the documents-folder panel renders the client picker, so Billing is
 *      never left looking at a PDF with nothing to do;
 *   2. the picker offers "+ Add new client" and chooses the parse's best match,
 *      which are the two things that make it usable rather than a list;
 *   3. the service is `required`;
 *   4. and Confirm is disabled on what is still to choose, not only on being
 *      in flight.
 *
 * The database holds both rules itself - `confirm_authorization_document`
 * refuses a document with no client and a new authorization with no service,
 * and `verify_authorization_documents.sql` asserts both. This check is about
 * nobody meeting either sentence.
 */
import { readFileSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const read = (p) => readFileSync(path.join(root, p), "utf8");

const PANEL = "app/(app)/billing/pending-authorizations.tsx";
const PICKER = "app/(app)/admin/inbox/whose-document.tsx";
const PROPOSAL = "app/(app)/admin/inbox/inbox-view.tsx";

// ── 1. no dead end ───────────────────────────────────────────
const panel = read(PANEL);
// The whole tag, not the start of it: a fault that renamed the component to
// `<WhoseDocumentGone` passed a check looking for `"<WhoseDocument"`.
if (!/<WhoseDocument\s/.test(panel) || !/\bWhoseDocument\b[^<]*from "/.test(panel.replace(/\n/g, " "))) {
  problems.push(
    `${PANEL} does not offer the client picker, so a PDF whose folder is not a client is a dead end for Billing again.`,
  );
} else if (/not a client yet/.test(panel)) {
  problems.push(
    `${PANEL} still tells Billing to wait for the administrator. Saying whose a document is has been theirs to do since 0375.`,
  );
} else {
  ok("the documents-folder panel asks whose the PDF is");
}

// ── 2. the picker is usable ──────────────────────────────────
const picker = read(PICKER);
for (const [what, rule] of [
  ['"+ Add new client" as an option', /value="__new__"/],
  ["the parse's best match, chosen already", /bestMatch\(/],
  ["a box to search the list with", /Search the clients/],
]) {
  if (!rule.test(picker)) problems.push(`${PICKER} has lost ${what}.`);
}
if (!problems.length) ok("it is searched rather than scrolled, with the best match chosen and a way to add somebody new");

// ── 3 and 4. and Confirm waits for both ──────────────────
//
// Bounded to the component, and to the tag. The first version of this read
// "0 to 400 characters, lazily, up to a `>`" for the select - which stopped at
// the `>` inside `onChange={(e) => …}` and never reached the attribute it was
// looking for - and took the first gold submit button in the file, which
// belongs to another form altogether. Both passed a screen that was correct
// and would have passed one that was not.
const proposal = read(PROPOSAL);
const from = proposal.indexOf("export function AuthorizationProposal");
// The next top-level function is where this one ends.
const ends = from < 0 ? -1 : proposal.indexOf("\nfunction ", from);
const body = from < 0 ? "" : proposal.slice(from, ends < 0 ? proposal.length : ends);
if (!body) {
  problems.push(`${PROPOSAL} has no AuthorizationProposal, which means this check is reading the wrong thing.`);
} else {
  const at = body.indexOf('name="service_type"');
  const tag = at < 0 ? "" : body.slice(at, body.indexOf("<option", at));
  if (!tag) {
    problems.push(`${PROPOSAL} has no service dropdown, so this check cannot see whether it is required.`);
  } else if (!/\brequired\b/.test(tag)) {
    problems.push(`${PROPOSAL} asks for the service without requiring it, so Confirm goes to a refusal instead.`);
  } else {
    ok("the service is required");
  }

  const confirm = body.match(/<button className="btn gold" type="submit" disabled=\{([^}]*)\}/);
  if (!confirm) {
    problems.push(`${PROPOSAL} has no Confirm button this check can read, so whether it waits is unknown.`);
  } else if (!/missing/.test(confirm[1])) {
    problems.push(
      `${PROPOSAL} disables Confirm on "${confirm[1].trim()}" alone, so it can be pressed with the client or the service still unchosen.`,
    );
  } else {
    ok("and Confirm is disabled until both have been chosen");
  }
}

if (problems.length) {
  console.error(`\n${problems.length} problem(s):`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- A QUEUED PDF IS CONFIRMED WITH A CLIENT AND A SERVICE ---");
