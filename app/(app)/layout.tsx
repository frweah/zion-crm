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
import { SidebarToggle } from "./sidebar-toggle";
import { NavIcon } from "./nav-icons";
import { LiveMessaging } from "./live-messaging";
import { ClientSearch } from "./client-search";
import { createClient } from "@/lib/supabase/server";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  // Who is signed in, and the screen hints, asked together. Each separate wait
  // on Supabase's API costs about 75 ms however close the servers are
  // (measured 18 Sept 2026), so the hints no longer wait for the person. The
  // rules already limit both to the person asking; somebody who is not staff
  // is redirected by requireStaff before either is used.
  const supabase = await createClient();
  const [staff, { data: hints }, { data: seen }, { data: narrowPref }, { data: policyDue }, { data: unreadRows }] = await Promise.all([
    requireStaff(),
    supabase.from("tour_hints").select("key, screen, title, body, roles").eq("active", true),
    supabase.from("staff_prefs").select("key").like("key", "hint:%"),
    // Kept to icons by choice (the width alone does it below 1100px).
    supabase.from("staff_prefs").select("key").eq("key", "sidebar:narrow").maybeSingle(),
    // A policy version in force they have not signed (0103).
    supabase.rpc("policy_signature_due"),
    // Unread staff messages, for the sidebar's badge (0104).
    supabase.rpc("my_unread"),
  ]);
  const unread = (unreadRows ?? []).reduce((s, r) => s + (r.unread ?? 0), 0);
  const narrow = Boolean(narrowPref);
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
  if (staff.onboardingOpen && pathname && !pathname.startsWith("/paperwork")) {
    redirect("/paperwork/onboarding");
  }

  // A new version of a staff policy is signed before anything else, on the
  // next sign-in and every screen after until it is (owner, 19 Sept 2026).
  // The onboarding walkthrough has its own policy step, so it goes first.
  if (policyDue === true && !staff.onboardingOpen && pathname && !pathname.startsWith("/paperwork")) {
    redirect("/paperwork/policy");
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
          <Image src="/zion-logo.png" alt="" width={36} height={36} priority />
          <span className="side-label">Zion Voc Rehab</span>
        </div>

        {/* It reads ?tab= to tell same-path screens apart, like the tab strip. */}
        <Suspense fallback={null}>
          <NavLinks groups={nav} />
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
          aria-label="Copilot: Microsoft 365 Copilot Chat, opens in a new tab"
        >
          <NavIcon name="copilot" />
          <span className="side-label">Copilot</span>
        </a>

        <SidebarToggle initial={narrow} />

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
          <QuickAdd />
        </div>

        <Suspense fallback={null}>
          <GroupTabs groups={nav} />
        </Suspense>

        {hint && <HintBar hintKey={hint.key} title={hint.title} body={hint.body} />}
        {children}
      </main>
      <LiveMessaging myId={staff.id} initialUnread={unread} />
    </div>
  );
}
