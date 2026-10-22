import type { Metadata } from "next";
import { requirePortal } from "@/lib/portal/session";
import { createClient } from "@/lib/supabase/server";
import { DocumentsView, type PortalRequest } from "../_components/views";

export const metadata: Metadata = { title: "Documents" };
export const dynamic = "force-dynamic";

export default async function PortalDocumentsPage() {
  const me = await requirePortal();
  const supabase = await createClient();
  const { data } = await supabase.rpc("portal_my_requests");
  return <DocumentsView me={me} requests={(data ?? []) as PortalRequest[]} />;
}
