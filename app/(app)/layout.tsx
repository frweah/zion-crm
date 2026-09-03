import Image from "next/image";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { ROLE_LABEL, ROLE_NAV, ORG, canReach } from "@/lib/roles";
import { NavLinks } from "./nav-links";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const staff = await requireStaff();
  const nav = ROLE_NAV[staff.role];

  // Typing a URL should get you no further than the navigation does. Every
  // role has Dashboard, so this cannot loop.
  const pathname = (await headers()).get("x-pathname") ?? "";
  if (pathname && !canReach(staff.role, pathname)) {
    redirect("/dashboard");
  }

  return (
    <div className="shell">
      <nav className="side">
        <div className="brand">
          <Image src="/zion-logo.png" alt="" width={52} height={52} priority />
          <span>
            Zion Voc Rehab
            <small>CRM</small>
          </span>
        </div>

        <NavLinks items={nav} />

        <div className="roleblock">
          <div style={{ color: "#fff", fontWeight: 500 }}>{staff.name}</div>
          <div>{ROLE_LABEL[staff.role]}</div>
          <div style={{ marginTop: 6, fontSize: 11 }}>
            Counselors {ORG.phone} · Clients {ORG.clientPhone}
          </div>
          <form action="/auth/signout" method="post" style={{ marginTop: 10 }}>
            <button
              className="navb"
              type="submit"
              style={{ border: "1px solid var(--forest-3)", cursor: "pointer" }}
            >
              Sign out
            </button>
          </form>
        </div>
      </nav>

      <main className="main">{children}</main>
    </div>
  );
}
