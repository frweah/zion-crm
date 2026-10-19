"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

/**
 * Setting up a second factor, and using it.
 *
 * All of the cryptography is Supabase's. What is here is the states a person
 * can be in and the words for each: they have not set one up, they are part
 * way through setting one up, they have one and this session is being asked
 * for a code, or they are through.
 *
 * The secret is shown as a QR code and also in writing, because somebody
 * setting this up on the same phone they are reading it on cannot photograph
 * their own screen.
 *
 * Three things here are the fix for 19 Oct, when enrolling appeared to do
 * nothing at all. The database was right the whole time - the factor saved,
 * verified, and the roster showed it - and the screen was wrong in three
 * ways, each of which on its own looks exactly like silence:
 *
 *   There was no state for having succeeded. A good code cleared the form
 *   and left the person on a screen asking for a code, which they then gave,
 *   successfully, forever. `done` is the acknowledgement that was missing.
 *
 *   Nothing was caught. An error thrown rather than handed back in the result
 *   skipped past setBusy(false) and showed nothing at all, leaving the button
 *   reading "Checking..." with no reason given.
 *
 *   The code form picked the first factor on the account. An abandoned
 *   attempt leaves an unverified one behind, and answering a challenge on
 *   that asks for a secret nobody ever scanned, so every code is wrong.
 */
type Enrolling = { factorId: string; qr: string; secret: string };

/** Which of the two things just worked, because they deserve different words. */
type Done = "enrolled" | "stepped";

export function Enrol({
  hasFactor,
  required,
  stepped,
}: {
  hasFactor: boolean;
  required: boolean;
  stepped: boolean;
}) {
  const router = useRouter();
  const [starting, setStarting] = useState(false);
  const [enrolling, setEnrolling] = useState<Enrolling | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<Done | null>(null);

  /** Something thrown rather than handed back still has to say why. */
  const because = (err: unknown, fallback: string) =>
    (err instanceof Error && err.message) || fallback;

  async function start() {
    setError(null);
    setStarting(true);
    try {
      const supabase = createClient();
      const { data, error: enrolError } = await supabase.auth.mfa.enroll({
        factorType: "totp",
        friendlyName: `Zion CRM ${new Date().toISOString().slice(0, 10)}`,
      });
      if (enrolError || !data) {
        setError(enrolError?.message ?? "That did not start. Try again.");
        return;
      }
      setCode("");
      setEnrolling({ factorId: data.id, qr: data.totp.qr_code, secret: data.totp.secret });
    } catch (err) {
      setError(because(err, "That did not start. Check the connection and try again."));
    } finally {
      setStarting(false);
    }
  }

  /** Confirms a new factor, or answers the challenge on an existing one. */
  async function submit(factorId: string, outcome: Done) {
    setError(null);
    setBusy(true);
    try {
      const supabase = createClient();
      const { error: verifyError } = await supabase.auth.mfa.challengeAndVerify({
        factorId,
        code: code.replace(/\s/g, ""),
      });
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
      setDone(outcome);
      router.refresh();
    } catch (err) {
      setError(because(err, "That code could not be checked. Check the connection and try again."));
    } finally {
      setBusy(false);
    }
  }

  // ── it worked, and the screen says so ─────────────────────
  if (done) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Two-step sign-in is on</h3>
        <p className="sub">
          {done === "enrolled"
            ? "Your phone is set up. A code is asked for next time you sign in."
            : "That code was right. This sign-in is confirmed."}
        </p>
        <button className="btn gold" type="button" onClick={() => router.push("/dashboard")}>
          Go to Home
        </button>
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
            await submit(enrolling.factorId, "enrolled");
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

  // ── they have one, and this session still owes us a code ──
  //
  // Only when the practice requires one, because that is the only time the
  // layout sends somebody here for it. Somebody who came of their own accord
  // to look at the setting is not made to prove anything.
  if (hasFactor && required && !stepped) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Enter the code from your app</h3>
        <p className="sub">Six digits, from the authenticator app you set up.</p>
        {error && <div className="alert bad">{error}</div>}
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            setError(null);
            try {
              const supabase = createClient();
              const { data, error: listError } = await supabase.auth.mfa.listFactors();
              if (listError) {
                setError(listError.message);
                return;
              }
              // The verified one, not merely the first: an abandoned attempt
              // leaves an unverified factor whose secret nobody ever scanned.
              const factor = data?.totp?.find((f) => f.status === "verified");
              if (!factor) {
                setError(
                  "Your second factor is not on this account any more. Ask the administrator.",
                );
                return;
              }
              await submit(factor.id, "stepped");
            } catch (err) {
              setError(because(err, "That could not be checked. Try again."));
            }
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

  // ── they have one, and there is nothing to do ─────────────
  if (hasFactor) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Two-step sign-in is on</h3>
        <p className="sub">
          {stepped ? "This sign-in used it." : "A code is asked for when you sign in."}
        </p>
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
