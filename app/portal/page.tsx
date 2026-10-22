import type { Metadata } from "next";
import { requirePortal } from "@/lib/portal/session";
import { createClient } from "@/lib/supabase/server";
import { HomeView } from "./_components/views";

export const metadata: Metadata = { title: "Home" };
export const dynamic = "force-dynamic";

export default async function PortalHomePage() {
  const me = await requirePortal();
  const supabase = await createClient();
  const { data: unread } = await supabase.rpc("portal_unread");
  return <HomeView me={me} unread={unread ?? 0} />;
}
