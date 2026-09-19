import { NextResponse, type NextRequest } from "next/server";
import { randomBytes } from "node:crypto";
import { cookies } from "next/headers";
import { getCurrentStaff } from "@/lib/session";
import { authorizeUrl, pkce, microsoftConfigured } from "@/lib/microsoft";

/**
 * Starts the connection.
 *
 * The PKCE verifier and the state both go into short-lived, http-only cookies
 * rather than into the URL or a table. They are single-use, they belong to
 * this browser and no other, and ten minutes is longer than anybody takes to
 * click through a consent screen.
 */
export async function GET(request: NextRequest) {
  const me = await getCurrentStaff();
  if (!me) {
    return NextResponse.redirect(new URL("/login", process.env.NEXT_PUBLIC_SITE_URL!));
  }

  if (!microsoftConfigured()) {
    return NextResponse.redirect(
      new URL("/dashboard?microsoft=unconfigured", process.env.NEXT_PUBLIC_SITE_URL!),
    );
  }

  // Only Admin is ever asked for the shared-mailbox permission, and only when
  // connecting for that purpose. Everybody else consents to their own mailbox
  // and nothing wider.
  const shared = request.nextUrl.searchParams.get("shared") === "1" && me.role === "Admin";

  // Turning sending on (Messaging brief, M): Mail.Send, and for the roles that
  // work the shared mailbox (Admin and Billing) the permission to read it -
  // which opens only a mailbox Exchange has already given them.
  const send = request.nextUrl.searchParams.get("send") === "1";
  const sharedToo = shared || (send && (me.role === "Admin" || me.role === "Billing"));

  const state = randomBytes(16).toString("base64url");
  const { verifier, challenge } = pkce();

  const jar = await cookies();
  const options = {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax" as const,
    path: "/api/auth/microsoft",
    maxAge: 600,
  };
  jar.set("ms_state", state, options);
  jar.set("ms_verifier", verifier, options);

  return NextResponse.redirect(authorizeUrl(state, challenge, sharedToo, send));
}
