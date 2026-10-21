import type { Metadata } from "next";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { VerifyView } from "../_components/views";

export const metadata: Metadata = { title: "Enter your code" };

export default async function PortalVerifyPage() {
  const jar = await cookies();
  if (!jar.get("zion_portal_attempt")?.value) redirect("/portal/sign-in?ended=code");
  const via = jar.get("zion_portal_via")?.value === "email" ? "email" : "text";
  return <VerifyView via={via} />;
}
