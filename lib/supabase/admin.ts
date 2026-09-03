import "server-only";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

/**
 * Service-role client. Bypasses RLS completely.
 *
 * Only for operations Supabase Auth requires an admin key for — sending a
 * staff invite, and revoking sessions when an account is deactivated. Never
 * use it to read or write client data: that is what the RLS-bound client is
 * for, and routing client data through here would defeat the whole model.
 */
export function createAdminClient() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new Error("SUPABASE_SERVICE_ROLE_KEY is not set");

  return createClient<Database>(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
