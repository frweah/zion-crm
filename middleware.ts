import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

/**
 * Refreshes the Supabase session cookie on every request and keeps
 * unauthenticated visitors out of the app.
 *
 * This is a gate, not the security boundary — RLS is. Someone who got past
 * this would still see nothing without an active staff row.
 *
 * It also forwards the pathname as a header, because the app layout needs it
 * to keep each role off the screens its role does not include.
 */
/**
 * Paths that skip the session gate.
 *
 * /api/cron and /api/health are here because their callers have no session —
 * they authenticate with a shared secret each route checks itself. Listed one
 * by one, never /api as a whole: a future API route that forgets to authorize
 * should be caught by this gate rather than quietly exposed by it. The cost of
 * that strictness is that a new machine endpoint has to be added here, which
 * is a better failure than the alternative.
 */
const PUBLIC_PATHS = [
  "/login",
  "/auth",
  "/no-access",
  "/api/cron",
  "/api/health",
  "/api/sms",
  "/api/agent",
];
// /api/cron already covers the sync sweep — it arrives with a shared secret
// and no session, because there is nobody signed in at three in the morning.
//
// /api/sms is the inbound webhook. GoHighLevel posts a client's reply to it
// with no session and its own shared secret, which the route checks. Without
// this line the gate redirects that POST to the login page and the reply is
// lost — including a STOP, which is the one message that must never be
// dropped. It was missing for a day and nothing said so: the redirect is a
// 307 to a page, so the caller sees a success and there is nothing in any log
// to notice.
//
// /api/agent is the document agent on the owner's machine. Same shape: no
// session, its own shared secret, checked by both routes behind it.

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-pathname", pathname);

  let response = NextResponse.next({ request: { headers: requestHeaders } });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request: { headers: requestHeaders } });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // Do not remove: this call is what refreshes the session cookie.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const isPublic = PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(p + "/"));

  if (!user && !isPublic) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("next", pathname);
    return NextResponse.redirect(url);
  }

  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)"],
};
