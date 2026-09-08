import { NextResponse, type NextRequest } from "next/server";
import { cookies } from "next/headers";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { exchangeCode, fetchMe } from "@/lib/microsoft";

const site = () => process.env.NEXT_PUBLIC_SITE_URL!;
const back = (params: string) => NextResponse.redirect(new URL(`/dashboard?${params}`, site()));

/**
 * Finishes the connection.
 *
 * Everything that can go wrong here goes back to the dashboard as a short
 * message rather than a stack trace: the person did nothing wrong by declining
 * a consent screen, and a page of JSON would tell them nothing.
 *
 * The tokens go straight from the exchange into the encrypting function. They
 * are never written to a log, never put in a cookie, and never sent to the
 * browser.
 */
export async function GET(request: NextRequest) {
  const me = await getCurrentStaff();
  if (!me) return NextResponse.redirect(new URL("/login", site()));

  const params = request.nextUrl.searchParams;
  const jar = await cookies();

  const clear = () => {
    jar.delete("ms_state");
    jar.delete("ms_verifier");
  };

  // Microsoft reports a refusal here rather than by failing the request.
  const error = params.get("error");
  if (error) {
    clear();
    return back(
      error === "access_denied"
        ? "microsoft=declined"
        : `microsoft=error&detail=${encodeURIComponent(error)}`,
    );
  }

  const code = params.get("code");
  const state = params.get("state");
  const expectedState = jar.get("ms_state")?.value;
  const verifier = jar.get("ms_verifier")?.value;

  clear();

  if (!code || !state || !verifier || state !== expectedState) {
    // Either somebody arrived here without starting the flow, or the attempt
    // is older than the cookies. Both mean start again rather than continue.
    return back("microsoft=expired");
  }

  try {
    const tokens = await exchangeCode(code, verifier);
    const profile = await fetchMe(tokens.accessToken);

    const supabase = await createClient();
    const { error: saveError } = await supabase.rpc("set_microsoft_tokens", {
      p_microsoft_user_id: profile.id,
      p_email: profile.email,
      p_display_name: profile.displayName,
      p_scopes: tokens.scope,
      p_access: tokens.accessToken,
      p_refresh: tokens.refreshToken,
      p_expires_at: tokens.expiresAt.toISOString(),
    });

    if (saveError) throw new Error(saveError.message);

    return back("microsoft=connected");
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown error";
    // Server-side, because the reason matters and the person cannot act on it.
    console.error("Microsoft connection failed", message);
    return back(`microsoft=failed&detail=${encodeURIComponent(message.slice(0, 200))}`);
  }
}
