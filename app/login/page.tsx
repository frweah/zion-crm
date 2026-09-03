"use client";

import { useActionState } from "react";
import { useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { signIn, sendPasswordReset, type LoginState } from "./actions";
import { ORG } from "@/lib/roles";

const initial: LoginState = { error: null };

function LoginForm() {
  const params = useSearchParams();
  const next = params.get("next") ?? "/dashboard";

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
