import { requireAdmin } from "@/lib/session";
import StaffSection from "../staff/section";
import ContractorsSection from "../contractors/section";

/**
 * Admin → People.
 *
 * Everybody who works here, on one page: accounts and roles, pay rates,
 * onboarding and offboarding, certifications and documents, then contractors -
 * their 1099 details, the payments made, the tax-year settings and the 1099
 * runs. These were the Staff and Contractors screens; the old paths redirect
 * here.
 */
export default async function PeoplePage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; year?: string }>;
}) {
  await requireAdmin();

  return (
    <>
      <nav className="row2 no-print" aria-label="On this page" style={{ gap: 16, marginBottom: 12, fontSize: 13 }}>
        <a href="#staff">Staff, pay, onboarding and certifications</a>
        <a href="#contractors">Contractors and 1099s</a>
      </nav>

      <section id="staff">
        <StaffSection searchParams={searchParams} />
      </section>

      <section id="contractors" style={{ marginTop: 40, paddingTop: 24, borderTop: "1px solid var(--line)" }}>
        <ContractorsSection searchParams={searchParams} />
      </section>
    </>
  );
}
