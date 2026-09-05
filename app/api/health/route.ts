import { NextResponse, type NextRequest } from "next/server";

/**
 * What this deployment is actually configured with.
 *
 * Added after an afternoon of not being able to tell whether a failing login
 * meant a wrong password or a misconfigured deployment. Guessing at that from
 * the outside is impossible by design — the login page deliberately gives the
 * same answer either way — so the deployment has to be able to say.
 *
 * Never returns a secret. For anything sensitive it reports only whether the
 * value is present, its length, and a short fingerprint, which is enough to
 * tell "missing" from "wrong" from "correct" without printing the value.
 *
 * Behind CRON_SECRET, same as the cron endpoint.
 */
export const dynamic = "force-dynamic";

function describe(value: string | undefined) {
  if (!value) return { set: false };
  return {
    set: true,
    length: value.length,
    fingerprint: `${value.slice(0, 6)}…${value.slice(-4)}`,
  };
}

export async function GET(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "CRON_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  const env = {
    // Not a secret — it identifies which project this deployment talks to,
    // which is the single most useful fact when logins fail.
    NEXT_PUBLIC_SUPABASE_URL: supabaseUrl ?? null,
    NEXT_PUBLIC_SITE_URL: process.env.NEXT_PUBLIC_SITE_URL ?? null,
    EMAIL_FROM: process.env.EMAIL_FROM ?? null,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: describe(anonKey),
    SUPABASE_SERVICE_ROLE_KEY: describe(process.env.SUPABASE_SERVICE_ROLE_KEY),
    RESEND_API_KEY: describe(process.env.RESEND_API_KEY),
    CRON_SECRET: describe(secret),
  };

  // Does this deployment's Supabase actually answer, with the key it holds?
  let supabaseReachable: unknown = "not attempted";
  if (supabaseUrl && anonKey) {
    try {
      const res = await fetch(`${supabaseUrl}/auth/v1/settings`, {
        headers: { apikey: anonKey },
        cache: "no-store",
      });
      supabaseReachable = { status: res.status, ok: res.ok };
    } catch (err) {
      supabaseReachable = { error: err instanceof Error ? err.message : "unknown" };
    }
  }

  const missing = Object.entries(env)
    .filter(([, v]) => v === null || (typeof v === "object" && v !== null && "set" in v && !v.set))
    .map(([k]) => k);

  return NextResponse.json({
    ok: missing.length === 0,
    missing,
    env,
    supabaseReachable,
    deployment: {
      vercelUrl: process.env.VERCEL_URL ?? null,
      environment: process.env.VERCEL_ENV ?? null,
      commit: process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ?? null,
    },
  });
}
