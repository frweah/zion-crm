"use client";

import { useActionState } from "react";
import { setPassword, type PasswordState } from "./actions";

const initial: PasswordState = { error: null };

export default function SetPasswordPage() {
  const [state, action, pending] = useActionState(setPassword, initial);

  return (
    <main className="centre">
      <div className="panel">
        <h1>Choose a password</h1>
        <p className="sub">
          This is your own login. Do not share it — the data-handling policy you signed covers
          this.
        </p>

        {state.error && <div className="alert bad">{state.error}</div>}

        <form action={action}>
          <label className="field">
            New password
            <input name="password" type="password" autoComplete="new-password" required />
          </label>
          <label className="field">
            Confirm password
            <input name="confirm" type="password" autoComplete="new-password" required />
          </label>
          <button className="btn" type="submit" disabled={pending} style={{ width: "100%" }}>
            {pending ? "Saving…" : "Save password and continue"}
          </button>
        </form>
      </div>
    </main>
  );
}
