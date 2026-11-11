import "server-only";
import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff, type CurrentStaff } from "@/lib/session";
import { gateFor } from "@/lib/gates";

/**
 * Who is asking, for the phone's own addresses under /api/phone.
 *
 * The phone screens are a page like any other and the layout holds them to
 * the three gates. These addresses are not pages - a phone can ask them
 * directly - so each one asks the same question itself, through the same
 * function (lib/gates.ts). A password-only session in a practice that
 * requires a second factor gets nothing from here, the same as it gets
 * nothing from a screen.
 *
 * The answers say which of three things happened, because the phone does a
 * different thing for each: not signed in (keep what is waiting, ask them to
 * sign in), a gate (send them to it), and a database that did not answer
 * (try again later). None of them is "no".
 */
export async function phoneStaff(): Promise<
  | { staff: CurrentStaff; supabase: Awaited<ReturnType<typeof createClient>> }
  | { response: NextResponse }
> {
  const staff = await getCurrentStaff();
  if (!staff) {
    return { response: NextResponse.json({ signedOut: true, error: "Sign in again to send." }, { status: 401 }) };
  }
  const supabase = await createClient();
  const [{ data: policyDue }, { data: twoFactorRows }, { data: claims }] = await Promise.all([
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
  if (gate) {
    return { response: NextResponse.json({ gate, error: "Finish signing in first." }, { status: 403 }) };
  }
  return { staff, supabase };
}

/** Nothing the phone reads is kept by anything between it and here. */
export function fresh(body: unknown, status = 200) {
  return NextResponse.json(body, { status, headers: { "Cache-Control": "no-store" } });
}
