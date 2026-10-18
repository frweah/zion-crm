"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

/**
 * Setting up a second factor, and using it.
 *
 * All of the cryptography is Supabase's. What is here is the three states a
 * person can be in and the words for each: they have not set one up, they are
 * part way through setting one up, or they have one and are being asked for a
 * code.
 *
 * The secret is shown as a QR code and also in writing, because somebody
 * setting this up on the same phone they are reading it on cannot photograph
 * their own screen.
 */
type Enrolling = { factorId: string; qr: string; secret: string };

export function Enrol({ hasFactor, required }: { hasFactor: boolean; required: boolean }) {
  const router = useRouter();
  const [starting, setStarting] = useState(false);
  const [enrolling, setEnrolling] = useState<Enrolling | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function start() {
    setError(null);
    setStarting(true);
    const supabase = createClient();
    const { data, error: enrolError } = await supabase.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: `Zion CRM ${new Date().toISOString().slice(0, 10)}`,
    });
    setStarting(false);
    if (enrolError || !data) {
      setError(enrolError?.message ?? "That did not start. Try again.");
      return;
    }
    setEnrolling({ factorId: data.id, qr: data.totp.qr_code, secret: data.totp.secret });
  }

  /** Confirms a new factor, or answers the challenge on an existing one. */
  async function submit(factorId: string) {
    setError(null);
    setBusy(true);
    const supabase = createClient();
    const { error: verifyError } = await supabase.auth.mfa.challengeAndVerify({
      factorId,
      code: code.replace(/\s/g, ""),
    });
    setBusy(false);
    if (verifyError) {
      setError(
        /invalid|incorrect/i.test(verifyError.message)
          ? "That code was not right. It changes every thirty seconds — try the one showing now."
          : verifyError.message,
      );
      return;
    }
    setCode("");
    setEnrolling(null);
    router.refresh();
  }

  // ── they have one, and are being asked for a code ─────────
  if (hasFactor && !enrolling) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Enter the code from your app</h3>
        <p className="sub">Six digits, from the authenticator app you set up.</p>
        {error && <div className="alert bad">{error}</div>}
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            const supabase = createClient();
            const { data } = await supabase.auth.mfa.listFactors();
            const factor = data?.totp?.[0];
            if (!factor) {
              setError("Your second factor is not on this account any more. Ask the administrator.");
              return;
            }
            await submit(factor.id);
          }}
          className="row2"
          style={{ alignItems: "flex-end", gap: 8 }}
        >
          <label className="field" style={{ maxWidth: 200 }} htmlFor="tf-code">
            Code
            <input
              id="tf-code"
              inputMode="numeric"
              autoComplete="one-time-code"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              required
            />
          </label>
          <button className="btn gold" type="submit" disabled={busy}>
            {busy ? "Checking…" : "Let me in"}
          </button>
        </form>
      </div>
    );
  }

  // ── part way through setting one up ───────────────────────
  if (enrolling) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Scan this with your authenticator app</h3>
        <p className="sub">
          Microsoft Authenticator, Google Authenticator or 1Password all work. Then type the six
          digits it shows.
        </p>
        {/* Supabase returns the QR as an SVG data URL. */}
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={enrolling.qr} alt="" width={180} height={180} />
        <p className="lock">
          Cannot scan it? Type this into the app instead: <code>{enrolling.secret}</code>
        </p>
        {error && <div className="alert bad">{error}</div>}
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            await submit(enrolling.factorId);
          }}
          className="row2"
          style={{ alignItems: "flex-end", gap: 8 }}
        >
          <label className="field" style={{ maxWidth: 200 }} htmlFor="tf-new-code">
            Code
            <input
              id="tf-new-code"
              inputMode="numeric"
              autoComplete="one-time-code"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              required
            />
          </label>
          <button className="btn gold" type="submit" disabled={busy}>
            {busy ? "Checking…" : "Turn it on"}
          </button>
          <button className="btn ghost" type="button" onClick={() => setEnrolling(null)}>
            Start again
          </button>
        </form>
      </div>
    );
  }

  // ── nothing set up yet ────────────────────────────────────
  return (
    <div className="card">
      <h3 style={{ marginTop: 0 }}>Set up a second factor</h3>
      <p className="sub">
        {required
          ? "The practice requires one to open the CRM. It takes a minute and you only do it once."
          : "A code from your phone as well as your password. It takes a minute and you only do it once."}
      </p>
      {error && <div className="alert bad">{error}</div>}
      <button className="btn gold" type="button" onClick={start} disabled={starting}>
        {starting ? "Starting…" : "Set it up"}
      </button>
    </div>
  );
}
