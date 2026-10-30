import Image from "next/image";
import { Suspense } from "react";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { ROLE_LABEL, AREA_LABEL, LEVEL_LABEL, navFor, ORG, canReach } from "@/lib/roles";
import { NavLinks } from "./nav-links";
import { HintBar } from "./hint-bar";
import { QuickAdd } from "./quick-add";
import { GroupTabs } from "./group-tabs";
import { HubBack } from "./hub-back";
import { SidebarToggle } from "./sidebar-toggle";
import { HeaderBar } from "./header-bar";
import type { Theme } from "./theme-actions";
import { BottomBar } from "./bottom-bar";
import { NavIcon } from "./nav-icons";
import { LiveMessaging } from "./live-messaging";
import { TeamLink } from "./team-link";
import { TeamPane } from "./team-pane";
import { chatSettings } from "@/lib/chat-prefs";
import { ClientSearch } from "./client-search";
import { createClient } from "@/lib/supabase/server";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  // Who is signed in, and the screen hints, asked together. Each separate wait
  // on Supabase's API costs about 75 ms however close the servers are
  // (measured 18 Sept 2026), so the hints no longer wait for the person. The
  // rules already limit both to the person asking; somebody who is not staff
  // is redirected by requireStaff before either is used.
  const supabase = await createClient();
  const [staff, { data: hints }, { data: seen }, { data: narrowPref }, { data: themePref }, { data: chatPrefs }, { data: policyDue }, { data: twoFactorRows }, { data: claims }] =
    await Promise.all([
    requireStaff(),
    supabase.from("tour_hints").select("key, screen, title, body, roles").eq("active", true),
    supabase.from("staff_prefs").select("key").like("key", "hint:%"),
    // Kept to icons by choice (the width alone does it below 1100px).
    supabase.from("staff_prefs").select("key").eq("key", "sidebar:narrow").maybeSingle(),
    // Which theme they chose, for the menu to show as pressed. The painting
    // of it happened in the root layout, from the cookie.
    supabase.from("staff_prefs").select("value").eq("key", "theme").maybeSingle(),
    // The three Team chat settings, read here because the pop-up runs on every
    // page and so has to know on every page (0272-0275).
    supabase.from("staff_prefs").select("key").like("key", "chat:%"),
    // A policy version in force they have not signed (0103).
    supabase.rpc("policy_signature_due"),
    // Whether the practice requires a second factor, and whether they have
    // one (0217). Both in one answer, because this runs on every page.
    supabase.rpc("two_factor_state"),
    // How far this session has authenticated. aal1 is a password; aal2 means
    // a second factor was used on it.
    supabase.auth.getClaims(),
  ]);
  const twoFactor = Array.isArray(twoFactorRows) ? twoFactorRows[0] : null;
  const authLevel = (claims?.claims as { aal?: string } | undefined)?.aal;
  // The badge is worked out in one place, in the browser (live-messaging.tsx):
  // the conversations waiting for this person, and their unread mail.
  const narrow = Boolean(narrowPref);
  const themeValue = themePref?.value;
  const theme: Theme = themeValue === "light" || themeValue === "dark" ? themeValue : "system";
  const nav = navFor(staff);

  // Typing a URL should get you no further than the navigation does. Every
  // role has Dashboard, so this cannot loop.
  const pathname = (await headers()).get("x-pathname") ?? "";
  if (pathname && !canReach(staff, pathname)) {
    redirect("/dashboard");
  }

  // Somebody brought on through the walkthrough (0100) works through it before
  // anything else: the data-handling policy is signed before first use of the
  // system, and the rest comes with it. Paperwork stays open - the walkthrough
  // lives under it, and so do their own forms and documents. It can be left
  // and resumed; signing in again lands them back on it.
  // A system account (0120) is not a person: it has no onboarding to do and
  // no policy to sign, and the deploy check it runs has to reach every screen.
  if (staff.onboardingOpen && !staff.isSystem && pathname && !pathname.startsWith("/paperwork")) {
    redirect("/paperwork/onboarding");
  }

  // A new version of a staff policy is signed before anything else, on the
  // next sign-in and every screen after until it is (owner, 19 Sept 2026).
  // The onboarding walkthrough has its own policy step, so it goes first.
  if (policyDue === true && !staff.onboardingOpen && !staff.isSystem && pathname && !pathname.startsWith("/paperwork")) {
    redirect("/paperwork/policy");
  }

  /**
   * A second factor, when the practice requires one (0217).
   *
   * After onboarding and the policy, because somebody on their first morning
   * signs the data-handling policy before anything else, and before every
   * other screen, because that is what requiring it means.
   *
   * Two cases arrive here and the screen tells them apart: no factor at all,
   * and a factor this session has not used yet. The system account has
   * neither a phone nor a person and is left alone, as it is by the
   * walkthrough above.
   *
   * It does nothing at all while org_settings.require_two_factor is off,
   * which is how it ships.
   */
  if (
    !staff.isSystem &&
    !staff.onboardingOpen &&
    pathname &&
    !pathname.startsWith("/security/two-factor") &&
    twoFactor?.required &&
    (!twoFactor.enrolled || authLevel !== "aal2")
  ) {
    redirect("/security/two-factor");
  }

  // The hint for this screen, if there is one this person has not put away.
  // Matched longest-first so /clients/<id> gets the record hint rather than
  // the list one.

  const dismissed = new Set((seen ?? []).map((p) => p.key));
  const hint =
    (hints ?? [])
      .filter((h) => !h.roles || h.roles.includes(staff.role))
      .filter((h) => pathname.startsWith(h.screen))
      .filter((h) => !dismissed.has(`hint:${h.key}`))
      .sort((a, b) => b.screen.length - a.screen.length)[0] ?? null;

  return (
    <div className={"shell" + (narrow ? " side-narrow" : "")}>
      <nav className="side" aria-label="Main">
        <div className="brand">
          {/* The logo as it is, on a white plate so the artwork reads against
              the green. The name beside it is the label; this is decoration. */}
          <span className="brand-plate">
            <Image src="/zion-logo.png" alt="" width={36} height={36} priority />
          </span>
          <span className="side-label">Zion Voc Rehab</span>
        </div>

        {/* It reads ?tab= to tell same-path screens apart, like the tab strip. */}
        <Suspense fallback={null}>
          <NavLinks groups={nav} narrow={narrow} />
        </Suspense>

        {/* Team, directly below the main tabs, with its own unread count
            (owner, 30 Oct 2026). Not inside a hub: a colleague asking
            something is not an errand to go and find, and it was three clicks
            down Communication. */}
        <Suspense fallback={null}>
          <TeamLink />
        </Suspense>

        {/* Microsoft 365 Copilot Chat: the one AI tool client information may
            go into (data-handling policy, rule 2). It opens in a new tab,
            outside the CRM; nothing from here is sent to it. */}
        <hr className="side-rule" />
        <a
          className="navb side-external"
          href="https://m365.cloud.microsoft/chat"
          target="_blank"
          rel="noopener noreferrer"
          title="Microsoft 365 Copilot Chat - opens in a new tab"
          aria-label="Assistant: Microsoft 365 Copilot Chat, opens in a new tab"
        >
          <NavIcon name="copilot" />
          {/* A plain noun in the sidebar; the tooltip and the label for a
              screen reader still name what it opens, because somebody
              should know they are leaving for a Microsoft product. */}
          <span className="side-label">Assistant</span>
        </a>

        <div className="roleblock">
          <div className="who side-label">{staff.name}</div>
          <div className="side-label">{ROLE_LABEL[staff.role]}</div>
          {staff.grants.length > 0 && (
            <div className="side-label" style={{ fontSize: "var(--text-xs)" }}>
              Also {staff.grants.map((g) => `${AREA_LABEL[g.area]} (${LEVEL_LABEL[g.level]})`).join(", ")}
            </div>
          )}
          <div className="side-label" style={{ marginTop: 6, fontSize: "var(--text-xs)" }}>
            Counselors {ORG.phone} · Clients {ORG.clientPhone}
          </div>
          <form action="/auth/signout" method="post" style={{ marginTop: 10 }}>
            <button className="btn ghost signout" type="submit" style={{ width: "100%" }} title="Sign out">
              <NavIcon name="sign-out" />
              <span className="side-label">Sign out</span>
            </button>
          </form>
        </div>

        {/* Last thing in the sidebar, and not one of the screens. */}
        <SidebarToggle initial={narrow} />
      </nav>

      <main className="main">
        {/* One place to add the six things people add all day, on every screen
            — the alternative is finding the client first, which is how a phone
            call ends up not written down. */}
        <div
          className="row2 no-print top-bar"
          style={{ justifyContent: "space-between", marginBottom: 10 }}
        >
          {/* The way to a client from wherever you are. It is on the left and
              first in the tab order because it is the commonest thing anybody
              does: the work is against a person, not against a screen. */}
          <ClientSearch />
          <div className="row2" style={{ gap: 10, alignItems: "center" }}>
            <QuickAdd />
            {/* What is waiting, and who you are (Design language, §1). */}
            <HeaderBar
              name={staff.name}
              role={ROLE_LABEL[staff.role]}
              theme={theme}
              extra={
                staff.grants.length > 0
                  ? `Also ${staff.grants.map((g) => `${AREA_LABEL[g.area]} (${LEVEL_LABEL[g.level]})`).join(", ")}`
                  : undefined
              }
            />
          </div>
        </div>

        <Suspense fallback={null}>
          <HubBack groups={nav} />
          <GroupTabs groups={nav} />
        </Suspense>

        {hint && <HintBar hintKey={hint.key} title={hint.title} body={hint.body} />}
        {children}
      </main>
      {/* The hubs where a thumb is, on a phone (Design language, §1). */}
      <Suspense fallback={null}>
        <BottomBar groups={nav} />
      </Suspense>
      <LiveMessaging myId={staff.id} settings={chatSettings(chatPrefs ?? [])} />
      {/* Over whatever page is open, so answering a colleague does not cost
          somebody the form they were filling in. */}
      <TeamPane myId={staff.id} />
    </div>
  );
}
