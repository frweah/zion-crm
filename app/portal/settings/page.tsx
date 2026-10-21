import type { Metadata } from "next";
import { requirePortal } from "@/lib/portal/session";
import { SettingsView } from "../_components/views";

export const metadata: Metadata = { title: "Settings" };

export default async function PortalSettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ texts?: string }>;
}) {
  const me = await requirePortal();
  const { texts } = await searchParams;
  return <SettingsView me={me} notice={texts} />;
}
