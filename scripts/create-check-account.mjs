/**
 * Makes an "Automated check" system account (0120, 0129) - run by the owner.
 *
 *   node --env-file=.env.local scripts/create-check-account.mjs [email]
 *   node --env-file=.env.local scripts/create-check-account.mjs --billing
 *
 * There are two, because a role only sees its own screens: the Job Search one
 * opens what Job Search reaches, and the Billing one opens Invoices,
 * Authorizations, the Service log, Export, Overview and Items - none of which
 * the first has ever been able to see (0129). Neither can write to a table,
 * and neither may be Admin: 0295 refuses it, because the read-only promise is
 * restrictive policies over tables and the functions gated on is_admin() are
 * not tables.
 *
 * A third was made as Intake & Reports and dropped (0296). It added no
 * screen - every screen Reports reaches, Job Search reaches too - so it was
 * a second password to issue for the same twenty screens. A role is worth an
 * account when it reaches something no other account can.
 *
 * It adds the staff row (is_system - read-only, never given an area beyond
 * its role) and then the sign-in, with a long random password it prints once,
 * to be pasted into GitHub → Settings → Secrets and variables → Actions as
 * SMOKE_EMAIL and SMOKE_PASSWORD. It is not written to any file, and nothing
 * else keeps it: lose it and run with --reset to issue a new one.
 *
 * **GitHub, not Vercel.** The checks that use these run in GitHub Actions;
 * Vercel never sees them, and a secret set there would do nothing at all.
 *
 * The email only has to be an address; nothing is ever sent to it - the
 * account is left out of every mailing and every list of colleagues.
 */
import { randomBytes } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const args = process.argv.slice(2);
const reset = args.includes("--reset");
const billing = args.includes("--billing");
const which = billing ? "billing" : "job-search";
const role = billing ? "Billing" : "Job Search";
const NAME = {
  "job-search": "Automated check",
  billing: "Automated check (billing)",
};
const SECRET = {
  "job-search": ["SMOKE_EMAIL", "SMOKE_PASSWORD"],
  billing: ["SMOKE_BILLING_EMAIL", "SMOKE_BILLING_PASSWORD"],
};
const email = (
  args.find((a) => a.includes("@")) ??
  {
    "job-search": "automated-check@zionvocrehab.com",
    billing: "automated-check-billing@zionvocrehab.com",
  }[which]
).toLowerCase();
const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be in .env.local");
  process.exit(1);
}
const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
const password = randomBytes(32).toString("base64url");

const { data: existing } = await admin
  .from("staff")
  .select("id, user_id, is_system, active")
  .eq("email", email)
  .maybeSingle();
if (existing && !existing.is_system) {
  console.error(`${email} is a person's staff account, not a system one. Choose another address.`);
  process.exit(1);
}
// A dropped account is not an address going spare. 0296 took the Reports one
// out of service and deleted its sign-in; handed that address, this script
// would have made a new password and linked it, putting the account back
// without anybody deciding to.
if (existing && !existing.active) {
  console.error(`${email} was taken out of service. Switch the staff row back on first if that is what you mean to do.`);
  process.exit(1);
}

if (existing?.user_id) {
  if (!reset) {
    console.error(`The automated-check account already exists. Run with --reset to issue a new password.`);
    process.exit(1);
  }
  const { error } = await admin.auth.admin.updateUserById(existing.user_id, { password });
  if (error) throw error;
} else {
  if (!existing) {
    // Staff first: an account can only be made for somebody already on staff.
    const { error } = await admin
      .from("staff")
      .insert({ name: NAME[which], email, role, active: true, is_system: true });
    if (error) throw error;
  }
  const { error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
}

const { data: linked } = await admin.from("staff").select("user_id").eq("email", email).maybeSingle();
if (!linked?.user_id) {
  console.error("The sign-in was made but is not linked to the staff row. Nothing to paste yet - check the staff table.");
  process.exit(1);
}

console.log("");
console.log("Paste these into GitHub → Settings → Secrets and variables → Actions:");
console.log("");
console.log(`  ${SECRET[which][0]}     ${email}`);
console.log(`  ${SECRET[which][1]}  ${password}`);
console.log(`  SUPABASE_URL    ${url}`);
console.log("  SUPABASE_ANON_KEY  (NEXT_PUBLIC_SUPABASE_ANON_KEY from .env.local)");
console.log("");
console.log("The password is shown this once and kept nowhere else.");
