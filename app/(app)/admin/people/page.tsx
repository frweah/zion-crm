import { requireAdmin } from "@/lib/session";
import { PageHead } from "../../page-head";
import StaffSection from "../staff/section";
import ContractorsSection from "../contractors/section";

/**
 * Admin → People.
 *
 * Everybody who works here, on one page: accounts and roles, pay rates,
 * onboarding and offboarding, certifications and documents, then contractors -
 * their 1099 details, the payments made and the 1099 runs. These were the
 * Staff and Contractors screens; the old paths redirect here. The tax-year
 * settings a 1099 run depends on are in Admin → System.
 */
export default async function PeoplePage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; year?: string }>;
}) {
  await requireAdmin();

  return (
    <>
      <PageHead
        title="People"
        context="Staff and contractors: accounts, pay, onboarding, certifications, and what a 1099 needs"
        toc={[
          ["staff", "Staff"],
          ["contractors", "Contractors and 1099s"],
        ]}
      />

      <section id="staff" className="page-section">
        <StaffSection searchParams={searchParams} />
      </section>

      <section id="contractors" className="page-section">
        <ContractorsSection searchParams={searchParams} />
      </section>
    </>
  );
}
