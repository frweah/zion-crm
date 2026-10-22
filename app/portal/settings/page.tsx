import type { Metadata } from "next";
import { requirePortal } from "@/lib/portal/session";
import { createClient } from "@/lib/supabase/server";
import { SettingsView, type NoticeOptions } from "../_components/views";

export const metadata: Metadata = { title: "Settings" };
export const dynamic = "force-dynamic";

export default async function PortalSettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ texts?: string }>;
}) {
  const me = await requirePortal();
  const { texts } = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.rpc("portal_my_notice_options");
  const options = ((data ?? []) as NoticeOptions[])[0] ?? null;
  return <SettingsView me={me} notice={texts} options={options} />;
}
