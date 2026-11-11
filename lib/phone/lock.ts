/**
 * Does this phone lock? (owner, 11 Nov 2026)
 *
 * "The app refuses to install or open on a phone with no passcode/biometric
 * lock where the browser can tell, and shows a one-time notice where it
 * cannot."
 *
 * No browser will say whether a phone has a passcode. The nearest thing it
 * will say is whether the phone offers websites its own unlock - fingerprint,
 * face or PIN - to confirm who is holding it (the Web Authentication
 * "user-verifying platform authenticator"). On Android that is offered only
 * once a screen lock is set, so "not offered" there is a phone with no lock.
 * Elsewhere the answer is less certain, which is why:
 *
 *   "locked"   - the phone offers its unlock. Open.
 *   "unlocked" - a phone, offering no unlock, on Android. Refused.
 *   "unknown"  - anything else: an iPhone that says no, a browser that cannot
 *                be asked, an error. The one-time notice.
 *
 * Refusing on "unknown" would lock staff out of the app on phones that are
 * properly locked, which is the wrong way for a check to be wrong.
 */
export type LockAnswer = "locked" | "unlocked" | "unknown";

export async function phoneLock(): Promise<LockAnswer> {
  try {
    const pkc = (window as unknown as {
      PublicKeyCredential?: { isUserVerifyingPlatformAuthenticatorAvailable?: () => Promise<boolean> };
    }).PublicKeyCredential;
    if (!pkc?.isUserVerifyingPlatformAuthenticatorAvailable) return "unknown";
    const offered = await pkc.isUserVerifyingPlatformAuthenticatorAvailable();
    if (offered) return "locked";
    const android = /android/i.test(navigator.userAgent);
    return android ? "unlocked" : "unknown";
  } catch {
    return "unknown";
  }
}

/** The one-time notice is answered per person per phone, so it is kept on the phone. */
const key = (staffId: string) => `zion-lock-confirmed:${staffId}`;

export function lockConfirmed(staffId: string): boolean {
  try {
    return localStorage.getItem(key(staffId)) === "yes";
  } catch {
    return false;
  }
}

export function confirmLock(staffId: string): void {
  try {
    localStorage.setItem(key(staffId), "yes");
  } catch {
    // Storage refused (a private window): the notice will ask again, which
    // is the safe way round.
  }
}

/** Everything this app put on the phone, for "Sign out on this phone". */
export async function clearPhone(): Promise<void> {
  try {
    for (const k of Object.keys(localStorage)) if (k.startsWith("zion-")) localStorage.removeItem(k);
  } catch {
    // Nothing kept there to clear.
  }
  try {
    if ("caches" in window) {
      for (const name of await caches.keys()) if (name.startsWith("zion-phone-")) await caches.delete(name);
    }
  } catch {
    // The worker is told as well, below.
  }
  navigator.serviceWorker?.controller?.postMessage("forget");
}
