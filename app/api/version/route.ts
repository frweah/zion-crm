import { NextResponse } from "next/server";

/**
 * Which commit this deployment is, and nothing else.
 *
 * The deploy check needs to know that the address staff use is already
 * serving the commit it is about to check: Vercel's per-deployment address is
 * behind Deployment Protection, so the check opens crm.zionvocrehab.com
 * instead, and has to wait for production to be moved there (28 Sept 2026 -
 * every screen "failed" because Vercel's own sign-in answered, not ours).
 *
 * /api/health says the same thing and much more, which is why it is behind
 * CRON_SECRET. This one is deliberately public: it is a commit hash of a
 * public repository, it says nothing about the practice, and a check that
 * needed a secret just to find out what is live would mean keeping that
 * secret in another place.
 */
export const dynamic = "force-dynamic";

export async function GET() {
  return NextResponse.json(
    { commit: process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ?? null },
    { headers: { "cache-control": "no-store" } },
  );
}
