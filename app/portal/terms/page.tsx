import type { Metadata } from "next";
import { createAdminClient } from "@/lib/supabase/admin";
import { TermsView, type Terms } from "../_components/views";

export const metadata: Metadata = { title: "Terms of use and privacy notice" };
export const dynamic = "force-dynamic";

/**
 * Readable before signing in: somebody deciding whether to use the portal has
 * to be able to read what they would be agreeing to. The terms are the one
 * thing read with the service role here, because they are not about anybody.
 */
export default async function PortalTermsPage() {
  const { data, error } = await createAdminClient()
    .from("portal_terms")
    .select("version, title, body")
    .eq("is_current", true)
    .maybeSingle();
  if (error) console.error(`[portal] the terms could not be read: ${error.message}`);
  return <TermsView terms={(data as Terms | null) ?? null} />;
}
