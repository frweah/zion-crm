/**
 * Sends a staff invite from the command line.
 *
 *   node --env-file=.env.local scripts/invite.mjs someone@zionvocrehab.com
 *
 * This exists for one job: bootstrapping the first Admin login, because the
 * Staff screen that sends invites is itself behind an Admin login. Every
 * account after that is invited from the Staff screen.
 *
 * The invite only works if an active staff row already exists for the address
 * — migration 0005 blocks the auth user otherwise.
 */
import { createClient } from "@supabase/supabase-js";
import pg from "pg";

const email = (process.argv[2] ?? "").trim().toLowerCase();
if (!email) {
  console.error("Usage: node --env-file=.env.local scripts/invite.mjs <email>");
  process.exit(1);
}

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";

if (!url || !serviceKey) {
  console.error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in .env.local");
  process.exit(1);
}

// Check the staff row first, so a typo gives a clear answer instead of an
// opaque database error from the trigger.
if (process.env.SUPABASE_DB_HOST && process.env.SUPABASE_DB_PASSWORD) {
  const db = new pg.Client({
    host: process.env.SUPABASE_DB_HOST,
    port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
    user: process.env.SUPABASE_DB_USER ?? "postgres",
    password: process.env.SUPABASE_DB_PASSWORD,
    database: "postgres",
    ssl: { rejectUnauthorized: false },
  });
  await db.connect();
  const { rows } = await db.query(
    "select name, role, active from public.staff where lower(email) = $1",
    [email],
  );
  await db.end();

  if (rows.length === 0) {
    console.error(`No staff account exists for ${email}. Add it first — the invite would be rejected.`);
    process.exit(2);
  }
  if (!rows[0].active) {
    console.error(`The staff account for ${email} is closed.`);
    process.exit(2);
  }
  console.log(`staff row: ${rows[0].name} — ${rows[0].role}`);
}

const supabase = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const { error } = await supabase.auth.admin.inviteUserByEmail(email, {
  redirectTo: `${site}/auth/confirm?type=invite`,
});

if (error) {
  console.error(`Invite failed: ${error.message}`);
  process.exit(3);
}

console.log(`Invite sent to ${email}. The link returns to ${site}/auth/confirm.`);
