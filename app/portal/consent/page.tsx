import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { requirePortal } from "@/lib/portal/session";
import { createClient } from "@/lib/supabase/server";
import { ConsentView, type Terms } from "../_components/views";

export const metadata: Metadata = { title: "Before you use the portal" };

export default async function PortalConsentPage({
  searchParams,
}: {
  searchParams: Promise<{ withdrawn?: string }>;
}) {
  const me = await requirePortal({ consented: false });
  if (me.electronic) redirect("/portal");
  const { withdrawn } = await searchParams;

  const supabase = await createClient();
  const { data } = await supabase
    .from("portal_terms")
    .select("version, title, body")
    .eq("is_current", true)
    .maybeSingle();

  return <ConsentView me={me} terms={(data as Terms | null) ?? null} withdrawn={withdrawn === "1"} />;
}
