import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

/**
 * Keeps unauthenticated visitors out of the app, and does nothing else.
 *
 * This is a gate, not the security boundary — RLS is, and the app layout's
 * requireStaff() is the check that decides whether somebody is really staff.
 * Someone who got past this would still see nothing.
 *
 * It also forwards the pathname as a header, because the app layout needs it
 * to keep each role off the screens its role does not include. That is free.
 *
 * ── why this is written so defensively (14 Oct 2026) ──
 *
 * Production returned 504 MIDDLEWARE_INVOCATION_TIMEOUT on every request for
 * part of an evening, and the middleware was the thing that turned a slow
 * database into a dead site. Three faults, all here:
 *
 *   It called supabase.auth.getUser(), which is a round trip to the auth
 *   server, on *every* request — and awaited it with no timeout. When the
 *   database slowed (p95 went from 400ms to 44 seconds), every request sat in
 *   the middleware until Vercel killed it. Nothing was served at all: not a
 *   page, not an asset, not the login screen.
 *
 *   It did that work even for paths it was about to wave through. /api/cron,
 *   /api/agent, /api/sms and /widget.js all authenticate themselves with a
 *   shared secret and have no session — and every one of them was paying for
 *   an auth round trip that could only ever return "no user".
 *
 *   And the 504s made it worse: a browser that gets no answer is reloaded, and
 *   the two polls in live-messaging keep firing, so the hour of the incident
 *   saw 16,957 database calls against a normal 300.
 *
 * So now: public paths cost nothing, the session is read from the cookie
 * rather than from the network, and anything that does go to the network is
 * bounded and cannot hang the request.
 */
const PUBLIC_PATHS = [
  "/login",
  "/auth",
  "/no-access",
  "/api/cron",
  "/api/health",
  "/api/version",
  "/api/sms",
  "/api/agent",
  "/api/widget",
  "/widget.js",
];
// Listed one by one, never /api as a whole: a future API route that forgets to
// authorize should be caught by this gate rather than quietly exposed by it.
// The cost of that strictness is that a new machine endpoint has to be added
// here, which is a better failure than the alternative.
//
// /api/cron is the sweeps - they arrive with a shared secret and no session,
// because there is nobody signed in at three in the morning.
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
//
// /api/version answers one question - which commit is serving this address -
// and holds nothing to protect. The deploy check asks it before opening a
// screen, so that it checks the deployment that went out rather than the one
// production had a moment earlier.
//
// /api/widget and /widget.js are the website chat (Messaging brief, C). These
// two are different from the others above: there is no secret, because the
// caller is a member of the public on zionrehabcenter.com who has no way to
// hold one. What stands in its place is that the browser is given nothing to
// hold - no database key, no conversation id - and that each route only
// answers the sites the practice named, and only ever acts on the one
// conversation the caller's token opens.

/**
 * How long the session check may take before the request goes on without it.
 *
 * Two seconds is far longer than a cookie read needs and far shorter than the
 * middleware's own limit, which is the window the incident lived in.
 */
const SESSION_TIMEOUT_MS = 2000;

/** Is there a Supabase auth cookie at all? Reading cookie names costs nothing. */
function hasSessionCookie(request: NextRequest): boolean {
  return request.cookies.getAll().some((c) => /^sb-.*-auth-token(\.\d+)?$/.test(c.name));
}

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-pathname", pathname);
  const pass = () => NextResponse.next({ request: { headers: requestHeaders } });

  // ── the cheapest thing first ───────────────────────────────
  // A path that authenticates itself does not need a session looked up, and
  // every one of these was paying for a round trip that could only ever say
  // "nobody is signed in".
  const isPublic = PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(p + "/"));
  if (isPublic) return pass();

  // ── no cookie, no session: nothing to ask anybody ──────────
  // The common case for a stranger, and it answers without touching Supabase.
  if (!hasSessionCookie(request)) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("next", pathname);
    return NextResponse.redirect(url);
  }

  let response = pass();

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
          response = pass();
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // ── the session, verified locally, bounded ─────────────────
  //
  // getClaims() checks the token's signature against the project's published
  // signing key (ES256), which each server caches for ten minutes - so this is
  // a verification rather than a cookie taken on trust, and it needs no round
  // trip to the Auth service. lib/session.ts already reads the signed-in
  // person this way; the middleware was the one place still asking the network
  // on every single request, and that is what hung.
  //
  // What is given up is promptness about a *revoked* session: a token that was
  // signed out elsewhere stays valid here until it expires, where asking the
  // Auth service would have caught it at once. Bounded, and small - the staff
  // row is still looked up on every page with active = true, so somebody
  // deactivated is locked out immediately, and RLS answers to the same claims.
  // A dead site is the worse failure.
  let signedIn = false;
  let timedOut = false;
  try {
    const result = await Promise.race([
      supabase.auth.getClaims(),
      new Promise<"timeout">((resolve) =>
        setTimeout(() => resolve("timeout"), SESSION_TIMEOUT_MS),
      ),
    ]);
    if (result === "timeout") timedOut = true;
    else signedIn = Boolean(result.data?.claims?.sub);
  } catch {
    // A refresh that threw is not a reason to hold the request open.
    timedOut = true;
  }

  // ── failing open ───────────────────────────────────────────
  // The session could not be settled in time. The request goes on rather than
  // hanging, because somebody holding an auth cookie is probably signed in and
  // the layout is about to check properly anyway - and because the alternative
  // is what took the site down: waiting, and then serving nothing at all.
  // Marked on the request so the layout and the idle check can see it happened.
  if (timedOut) {
    requestHeaders.set("x-session-check", "timed-out");
    return NextResponse.next({ request: { headers: requestHeaders } });
  }

  if (!signedIn) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("next", pathname);
    return NextResponse.redirect(url);
  }

  return response;
}

export const config = {
  // Everything except the things that never need a session: Next's own static
  // output, images, and the files a browser asks for by convention. The
  // narrower this is, the less there is to go wrong on a bad evening.
  matcher: [
    "/((?!_next/static|_next/image|_next/data|favicon.ico|robots.txt|sitemap.xml|manifest.webmanifest|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|css|js|map|woff2?)$).*)",
  ],
};
