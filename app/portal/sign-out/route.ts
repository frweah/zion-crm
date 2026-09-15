import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

/**
 * Ends the portal session in the database first, so it reads nothing even if
 * the browser kept a token, then this browser's sign-in. Local scope: signing
 * out on a shared computer must not sign the person out of their phone.
 */
export async function POST(request: NextRequest) {
  const supabase = await createClient();
  await supabase.rpc("portal_end_my_session");
  await supabase.auth.signOut({ scope: "local" });

  const reason = request.nextUrl.searchParams.get("reason") === "declined" ? "declined" : "signed-out";
  return NextResponse.redirect(new URL(`/portal/sign-in?ended=${reason}`, request.url), { status: 303 });
}
