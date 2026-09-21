/**
 * Makes the "Automated check" system account (0120) - run once, by the owner.
 *
 *   node --env-file=.env.local scripts/create-check-account.mjs [email]
 *
 * It adds the staff row (Job Search, is_system - read-only, never given more)
 * and then the sign-in, with a long random password it prints once, to be
 * pasted into GitHub → Settings → Secrets and variables → Actions as
 * SMOKE_EMAIL and SMOKE_PASSWORD. It is not written to any file, and nothing
 * else keeps it: lose it and run with --reset to issue a new one.
 *
 * The email only has to be an address; nothing is ever sent to it - the
 * account is left out of every mailing and every list of colleagues.
 */
import { randomBytes } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const args = process.argv.slice(2);
const reset = args.includes("--reset");
const email = (args.find((a) => a.includes("@")) ?? "automated-check@zionvocrehab.com").toLowerCase();
const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be in .env.local");
  process.exit(1);
}
const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
const password = randomBytes(32).toString("base64url");

const { data: existing } = await admin.from("staff").select("id, user_id, is_system").eq("email", email).maybeSingle();
if (existing && !existing.is_system) {
  console.error(`${email} is a person's staff account, not a system one. Choose another address.`);
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
      .insert({ name: "Automated check", email, role: "Job Search", active: true, is_system: true });
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
console.log(`  SMOKE_EMAIL     ${email}`);
console.log(`  SMOKE_PASSWORD  ${password}`);
console.log(`  SUPABASE_URL    ${url}`);
console.log("  SUPABASE_ANON_KEY  (NEXT_PUBLIC_SUPABASE_ANON_KEY from .env.local)");
console.log("");
console.log("The password is shown this once and kept nowhere else.");
