"use client";

import { useActionState, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { signIn, sendPasswordReset, type LoginState } from "./actions";
import { createClient } from "@/lib/supabase/client";
import { ORG } from "@/lib/roles";

const initial: LoginState = { error: null };

/**
 * Catches a sign-in link that landed here instead of /auth/confirm.
 *
 * When a redirect target is not on Supabase's allow-list, Supabase does not
 * refuse — it quietly sends the person to the project's Site URL instead, with
 * the session in the URL fragment. That lands on the front page, which
 * redirects here, and the fragment survives both hops because browsers carry
 * fragments across redirects.
 *
 * Without this the tokens are sitting right there in the address bar while the
 * person is told to sign in. Completing the session instead means a misplaced
 * allow-list entry degrades to "it still works" rather than "nobody can get
 * in", which is the difference between a settings nit and an outage.
 */
function useFragmentSession(): boolean {
  const [completing, setCompleting] = useState(false);

  useEffect(() => {
    const hash = window.location.hash.slice(1);
    if (!hash.includes("access_token")) return;

    const params = new URLSearchParams(hash);
    const access_token = params.get("access_token");
    const refresh_token = params.get("refresh_token");
    const type = params.get("type");
    if (!access_token || !refresh_token) return;

    setCompleting(true);
    (async () => {
      const supabase = createClient();
      const { error } = await supabase.auth.setSession({ access_token, refresh_token });
      if (error) {
        setCompleting(false);
        return;
      }
      // Clear the tokens out of the address bar before moving on.
      window.history.replaceState(null, "", window.location.pathname);
      window.location.replace(
        type === "recovery" || type === "invite" ? "/set-password" : "/dashboard",
      );
    })();
  }, []);

  return completing;
}

function LoginForm() {
  const params = useSearchParams();
  const next = params.get("next") ?? "/dashboard";
  const completingFragment = useFragmentSession();

  if (completingFragment) {
    return (
      <div className="panel">
        <h1>Signing you in…</h1>
        <p className="sub" style={{ marginBottom: 0 }}>
          One moment while your link is checked.
        </p>
      </div>
    );
  }

  const [signInState, signInAction, signingIn] = useActionState(signIn, initial);
  const [resetState, resetAction, resetting] = useActionState(sendPasswordReset, initial);

  const message = signInState.error ?? resetState.error;

  return (
    <div className="panel">
      <h1>Zion Vocational Rehab CRM</h1>
      <p className="sub">Sign in with your work email address.</p>

      {message && <div className="alert bad">{message}</div>}

      <form action={signInAction}>
        <input type="hidden" name="next" value={next} />
        <label className="field">
          Email
          <input name="email" type="email" autoComplete="username" required />
        </label>
        <label className="field">
          Password
          <input name="password" type="password" autoComplete="current-password" required />
        </label>
        <button className="btn" type="submit" disabled={signingIn} style={{ width: "100%" }}>
          {signingIn ? "Signing in…" : "Sign in"}
        </button>
      </form>

      <form action={resetAction} style={{ marginTop: 12 }}>
        <button className="btn ghost" type="submit" disabled={resetting} style={{ width: "100%" }}>
          {resetting ? "Sending…" : "Email me a password reset link"}
        </button>
        <p className="sub" style={{ marginTop: 8, marginBottom: 0, fontSize: 12 }}>
          Fill in your email above first.
        </p>
      </form>

      <p className="sub" style={{ marginTop: 20, marginBottom: 0, fontSize: 12 }}>
        Accounts are created by the administrator. If you have not been invited yet, contact{" "}
        {ORG.email}.
      </p>
    </div>
  );
}

export default function LoginPage() {
  return (
    <main className="centre">
      <Suspense fallback={<div className="panel">Loading…</div>}>
        <LoginForm />
      </Suspense>
    </main>
  );
}
