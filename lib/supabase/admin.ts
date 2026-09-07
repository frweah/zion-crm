import "server-only";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

/**
 * Service-role client. Bypasses RLS completely.
 *
 * For the few operations that genuinely need it: sending a staff invite,
 * revoking sessions when an account is deactivated, filing a signed tax form
 * into the Admin-only bucket, and deleting a stored object once the RLS-bound
 * client has already authorized the row delete. Never use it to read or write
 * client data: that is what the RLS-bound client is for, and routing client
 * data through here would defeat the whole model.
 */
export function createAdminClient() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new Error("SUPABASE_SERVICE_ROLE_KEY is not set");

  return createClient<Database>(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
