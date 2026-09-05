"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type LoginState = { error: string | null };

export async function signIn(_prev: LoginState, formData: FormData): Promise<LoginState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const next = String(formData.get("next") ?? "/dashboard");

  if (!email || !password) {
    return { error: "Enter your email address and password." };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    // The message to the person stays vague — it must not reveal whether an
    // address has an account. The reason goes to the server log, because
    // otherwise a misconfigured deployment and a mistyped password look
    // identical from both sides, and nobody can tell which they are chasing.
    console.error(
      `[auth] sign-in failed for ${email}: ${error.message} (status ${error.status ?? "?"}, code ${error.code ?? "?"})`,
    );
    return { error: "That email address and password did not match." };
  }

  revalidatePath("/", "layout");
  redirect(next.startsWith("/") ? next : "/dashboard");
}

export async function sendPasswordReset(
  _prev: LoginState,
  formData: FormData,
): Promise<LoginState> {
  const email = String(formData.get("email") ?? "").trim();
  if (!email) return { error: "Enter your email address first." };

  const supabase = await createClient();
  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";

  // No query string on the redirect: Supabase matches this against the
  // redirect allow-list and silently falls back to the Site URL if it does not
  // match, which sends people to the front page instead of the page that
  // completes the reset. A bare path is the most likely thing to be allowed.
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${site}/auth/confirm`,
  });

  if (error) {
    // Swallowing this was how a broken reset flow looked like a working one
    // for two days. The person still gets the same neutral answer.
    console.error(
      `[auth] password reset failed for ${email}: ${error.message} (status ${error.status ?? "?"})`,
    );
  }

  // Same answer either way, so this cannot be used to test for accounts.
  return { error: "If that address has an account, a reset link is on its way." };
}
