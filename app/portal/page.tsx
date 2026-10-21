import type { Metadata } from "next";
import { requirePortal } from "@/lib/portal/session";
import { HomeView } from "./_components/views";

export const metadata: Metadata = { title: "Home" };

export default async function PortalHomePage() {
  const me = await requirePortal();
  return <HomeView me={me} />;
}
