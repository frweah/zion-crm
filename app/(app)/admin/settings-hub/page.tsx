import Link from "next/link";
import { requireAdmin } from "@/lib/session";
import { PageHead } from "../../page-head";

/**
 * Settings, one feature at a time (Design language, §3).
 *
 * They were all on one page called System with a table of contents, which is
 * a filing cabinet with every drawer open. Each feature's settings are its
 * own page now, so changing the website chat means opening the website chat
 * rather than scrolling past the tax years to find it.
 *
 * What is not here: anything about billing. The brief leaves billing,
 * authorizations, forms and warrants alone, and so does this.
 */
const PAGES: { href: string; label: string; note: string }[] = [
  {
    href: "/admin/settings-hub/organization",
    label: "The practice",
    note: "Legal name, address, EIN, the numbers on a form.",
  },
  {
    href: "/admin/settings-hub/website-chat",
    label: "Website chat",
    note: "Who takes it, the hours it is offered, and what the bubble says.",
  },
  {
    href: "/admin/settings-hub/work",
    label: "Work and hours",
    note: "The categories people log against, and the mileage rate.",
  },
  {
    href: "/admin/settings-hub/notes",
    label: "Note headings",
    note: "What a note starts with, by kind.",
  },
  {
    href: "/admin/settings-hub/mailboxes",
    label: "Shared mailboxes",
    note: "Mailboxes read into client records.",
  },
  {
    href: "/admin/settings-hub/tax-years",
    label: "Tax years",
    note: "What a 1099 run depends on.",
  },
];

export default async function SettingsHub() {
  await requireAdmin();
  return (
    <>
      <PageHead title="Settings" context="One feature at a time" />
      <div className="hub-cards">
        {PAGES.map((p) => (
          <Link key={p.href} href={p.href} className="hub-card">
            <span className="hub-card-label">{p.label}</span>
            <span className="hub-card-note">{p.note}</span>
          </Link>
        ))}
      </div>
      <p className="lock" style={{ marginTop: 16 }}>
        The access log — who read what, and who was refused — is on{" "}
        <Link href="/admin/system">System</Link>, with the practice&rsquo;s own records.
      </p>
    </>
  );
}
