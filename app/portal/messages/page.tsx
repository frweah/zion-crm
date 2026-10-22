import type { Metadata } from "next";
import { requirePortal } from "@/lib/portal/session";
import { createClient } from "@/lib/supabase/server";
import { MessagesView, type PortalMessage } from "../_components/views";

export const metadata: Metadata = { title: "Messages" };
export const dynamic = "force-dynamic";

export default async function PortalMessagesPage() {
  const me = await requirePortal();
  const supabase = await createClient();
  const { data } = await supabase.rpc("portal_my_messages");
  return <MessagesView me={me} messages={(data ?? []) as PortalMessage[]} />;
}
