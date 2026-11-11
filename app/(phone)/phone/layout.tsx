import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { gateFor } from "@/lib/gates";
import "./phone.css";

export const metadata: Metadata = {
  title: "Zion",
  manifest: "/manifest.webmanifest",
  appleWebApp: { capable: true, title: "Zion", statusBarStyle: "default" },
};

/**
 * The phone app's frame (owner, 11 Nov 2026).
 *
 * Not inside app/(app), because the desk's frame - sidebar, header, search,
 * clock, the "+" - is what the phone was asked to do without: a short list
 * and one button. The rules that frame enforces are not left behind with it:
 * the same session, and the same three gates through the same function
 * (lib/gates.ts), so the phone asks for the second factor exactly when the
 * desk does.
 */
export default async function PhoneLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const [staff, { data: policyDue }, { data: twoFactorRows }, { data: claims }] = await Promise.all([
    requireStaff(),
    supabase.rpc("policy_signature_due"),
    supabase.rpc("two_factor_state"),
    supabase.auth.getClaims(),
  ]);
  const twoFactor = Array.isArray(twoFactorRows) ? twoFactorRows[0] : null;
  const gate = gateFor({
    pathname: "/phone",
    isSystem: staff.isSystem,
    onboardingOpen: staff.onboardingOpen,
    policyDue: policyDue === true,
    twoFactor: twoFactor ? { required: Boolean(twoFactor.required), enrolled: Boolean(twoFactor.enrolled) } : null,
    authLevel: (claims?.claims as { aal?: string } | undefined)?.aal,
  });
  if (gate) redirect(gate);

  return <div className="phone">{children}</div>;
}
