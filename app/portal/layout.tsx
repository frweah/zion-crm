import type { Metadata } from "next";
import Image from "next/image";
import { ORG } from "@/lib/roles";
import "./portal.css";

export const metadata: Metadata = {
  title: { default: "Client portal · Zion Vocational Rehab", template: "%s · Zion client portal" },
  robots: { index: false, follow: false },
};

/**
 * The portal's own frame: nothing from the CRM's shell, and a notice on every
 * screen, signed in or not, that this is not where to ask for help in an
 * emergency. The terms say it once; a person in trouble will not be reading
 * the terms.
 */
export default function PortalLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="portal">
      <a className="portal-skip" href="#main">
        Skip to main content
      </a>
      <header className="portal-header">
        <div className="portal-wrap">
          <Image src="/zion-logo.png" alt="" width={40} height={40} priority />
          <p className="portal-brand">
            Zion Vocational Rehab
            <span>Client portal</span>
          </p>
        </div>
      </header>

      {children}

      <footer className="portal-footer">
        <div className="portal-wrap">
          <p>
            <strong>This portal is not for emergencies.</strong> If you are in danger, call{" "}
            <a href="tel:911">911</a>. If you are in crisis, call or text <a href="tel:988">988</a>.
          </p>
          <p>
            Questions about the portal? Call Zion at{" "}
            <a href={`tel:+1${ORG.clientPhone.replace(/\D/g, "")}`}>{ORG.clientPhone}</a> or email{" "}
            <a href={`mailto:${ORG.email}`}>{ORG.email}</a>.
          </p>
          <p>
            <a href="/portal/terms">Terms of use and privacy notice</a>
          </p>
        </div>
      </footer>
    </div>
  );
}
