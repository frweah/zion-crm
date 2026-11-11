/**
 * Where somebody has to go before anything else, if anywhere.
 *
 * Three gates, in this order, which were written inline in the app layout and
 * are here now because the phone (app/(phone)) has to apply exactly the same
 * three - "same sign-in and 2FA" (owner, 11 Nov 2026). Two copies of the rule
 * that requires a second factor would be one rule and one place it drifted
 * from, and the drift would be the phone letting somebody in.
 *
 *   The onboarding walkthrough, for somebody brought on through it (0100).
 *   A policy version in force they have not signed.
 *   A second factor, when the practice requires one (0217).
 *
 * A system account (0120) is not a person and is held by none of them.
 * Nothing here reads the database: the layouts ask, and pass the answers in,
 * so this can be checked before every build with no credentials.
 */
export type GateFacts = {
  pathname: string;
  isSystem: boolean;
  onboardingOpen: boolean;
  policyDue: boolean;
  twoFactor: { required: boolean; enrolled: boolean } | null;
  /** How far this session has authenticated: aal1 a password, aal2 a second factor. */
  authLevel: string | undefined;
};

export function gateFor(f: GateFacts): string | null {
  if (f.isSystem || !f.pathname) return null;

  if (f.onboardingOpen && !f.pathname.startsWith("/paperwork")) {
    return "/paperwork/onboarding";
  }
  if (f.policyDue && !f.onboardingOpen && !f.pathname.startsWith("/paperwork")) {
    return "/paperwork/policy";
  }
  if (
    !f.onboardingOpen &&
    !f.pathname.startsWith("/security/two-factor") &&
    f.twoFactor?.required &&
    (!f.twoFactor.enrolled || f.authLevel !== "aal2")
  ) {
    return "/security/two-factor";
  }
  return null;
}
