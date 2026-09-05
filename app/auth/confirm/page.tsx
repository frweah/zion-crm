"use client";

import { useEffect, useState, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { ORG } from "@/lib/roles";

/**
 * Where invite, password-reset and magic links land.
 *
 * This was a server route that understood exactly one arrival shape —
 * `token_hash` — which is what Supabase sends only if the email templates have
 * been customised. The stock templates send `/auth/v1/verify?token=...`
 * instead, and after verifying, Supabase hands the session back as either a
 * `code` query parameter or an `#access_token` fragment. A fragment never
 * reaches the server at all, so no server route could have handled it.
 *
 * So this is a client page, and it accepts all three:
 *   - token_hash + type   (customised templates)
 *   - code                (PKCE)
 *   - #access_token       (implicit; invisible to the server)
 *
 * Accepting whatever arrives is worth more than insisting on one shape,
 * because the cost of getting it wrong is a staff member who cannot get in and
 * no clue as to why.
 */
function Confirm() {
  const router = useRouter();
  const params = useSearchParams();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      const supabase = createClient();

      const tokenHash = params.get("token_hash");
      const type = params.get("type");
      const code = params.get("code");
      const next = params.get("next");

      // Supabase reports failures in the query string too.
      const errorDescription = params.get("error_description") ?? params.get("error");

      const hash = typeof window !== "undefined" ? window.location.hash.slice(1) : "";
      const hashParams = new URLSearchParams(hash);
      const accessToken = hashParams.get("access_token");
      const refreshToken = hashParams.get("refresh_token");
      const hashError = hashParams.get("error_description") ?? hashParams.get("error");

      const arrivalType = type ?? hashParams.get("type");

      try {
        if (errorDescription || hashError) {
          throw new Error(errorDescription ?? hashError ?? "That link is no longer valid.");
        }

        if (accessToken && refreshToken) {
          const { error } = await supabase.auth.setSession({
            access_token: accessToken,
            refresh_token: refreshToken,
          });
          if (error) throw error;
        } else if (tokenHash && type) {
          const { error } = await supabase.auth.verifyOtp({
            type: type as "invite" | "recovery" | "magiclink" | "email",
            token_hash: tokenHash,
          });
          if (error) throw error;
        } else if (code) {
          const { error } = await supabase.auth.exchangeCodeForSession(code);
          if (error) throw error;
        } else {
          throw new Error(
            "That link did not carry a sign-in token. It may have already been used, or the email may have been forwarded.",
          );
        }

        if (cancelled) return;

        // An invited person has no password yet, and someone resetting theirs
        // is here to choose a new one.
        const destination =
          arrivalType === "invite" || arrivalType === "recovery"
            ? "/set-password"
            : (next ?? "/dashboard");

        // A full load rather than a client transition, so the server sees the
        // cookies the exchange just wrote.
        window.location.replace(destination);
      } catch (err) {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "That link could not be used.");
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [params, router]);

  if (error) {
    return (
      <div className="panel">
        <h1>That link did not work</h1>
        <div className="alert bad">{error}</div>
        <p className="sub">
          Links expire, and each one can only be used once. Ask the administrator to send a fresh
          invite, or use &ldquo;Email me a password reset link&rdquo; on the sign-in page.
        </p>
        <a className="btn ghost" href="/login" style={{ textDecoration: "none" }}>
          Back to sign in
        </a>
        <p className="sub" style={{ marginTop: 16, marginBottom: 0, fontSize: 12 }}>
          Still stuck? Contact {ORG.email}.
        </p>
      </div>
    );
  }

  return (
    <div className="panel">
      <h1>Signing you in…</h1>
      <p className="sub" style={{ marginBottom: 0 }}>
        One moment while your link is checked.
      </p>
    </div>
  );
}

export default function ConfirmPage() {
  return (
    <main className="centre">
      <Suspense
        fallback={
          <div className="panel">
            <h1>Signing you in…</h1>
          </div>
        }
      >
        <Confirm />
      </Suspense>
    </main>
  );
}
