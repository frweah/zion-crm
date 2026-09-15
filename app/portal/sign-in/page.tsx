import type { Metadata } from "next";
import { SignInView } from "../_components/views";

export const metadata: Metadata = { title: "Sign in" };

export default async function PortalSignInPage({
  searchParams,
}: {
  searchParams: Promise<{ ended?: string }>;
}) {
  const { ended } = await searchParams;
  return <SignInView ended={ended} />;
}
