import Image from "next/image";
import { Suspense } from "react";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { ROLE_LABEL, navFor, ORG, canReach } from "@/lib/roles";
import { NavLinks } from "./nav-links";
import { HintBar } from "./hint-bar";
import { QuickAdd } from "./quick-add";
import { GroupTabs } from "./group-tabs";
import { createClient } from "@/lib/supabase/server";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const staff = await requireStaff();
  const nav = navFor(staff.role);

  // Typing a URL should get you no further than the navigation does. Every
  // role has Dashboard, so this cannot loop.
  const pathname = (await headers()).get("x-pathname") ?? "";
  if (pathname && !canReach(staff.role, pathname)) {
    redirect("/dashboard");
  }

  // The hint for this screen, if there is one this person has not put away.
  // Matched longest-first so /clients/<id> gets the record hint rather than
  // the list one.
  const supabase = await createClient();
  const [{ data: hints }, { data: seen }] = await Promise.all([
    supabase.from("tour_hints").select("key, screen, title, body, roles").eq("active", true),
    supabase.from("staff_prefs").select("key").like("key", "hint:%"),
  ]);

  const dismissed = new Set((seen ?? []).map((p) => p.key));
  const hint =
    (hints ?? [])
      .filter((h) => !h.roles || h.roles.includes(staff.role))
      .filter((h) => pathname.startsWith(h.screen))
      .filter((h) => !dismissed.has(`hint:${h.key}`))
      .sort((a, b) => b.screen.length - a.screen.length)[0] ?? null;

  return (
    <div className="shell">
      <nav className="side">
        <div className="brand">
          <Image src="/zion-logo.png" alt="" width={36} height={36} priority />
          <span>
            Zion Vocational Rehab
            <small>CRM</small>
          </span>
        </div>

        {/* It reads ?tab= to tell same-path screens apart, like the tab strip. */}
        <Suspense fallback={null}>
          <NavLinks groups={nav} />
        </Suspense>

        <div className="roleblock">
          <div className="who">{staff.name}</div>
          <div>{ROLE_LABEL[staff.role]}</div>
          <div style={{ marginTop: 6, fontSize: 11 }}>
            Counselors {ORG.phone} · Clients {ORG.clientPhone}
          </div>
          <form action="/auth/signout" method="post" style={{ marginTop: 10 }}>
            <button className="btn ghost" type="submit" style={{ width: "100%" }}>
              Sign out
            </button>
          </form>
        </div>
      </nav>

      <main className="main">
        {/* One place to add the six things people add all day, on every screen
            — the alternative is finding the client first, which is how a phone
            call ends up not written down. */}
        <div
          className="row2 no-print"
          style={{ justifyContent: "flex-end", marginBottom: 10 }}
        >
          <QuickAdd />
        </div>

        <Suspense fallback={null}>
          <GroupTabs groups={nav} />
        </Suspense>

        {hint && <HintBar hintKey={hint.key} title={hint.title} body={hint.body} />}
        {children}
      </main>
    </div>
  );
}
