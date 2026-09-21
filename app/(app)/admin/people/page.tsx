import { requireAdmin } from "@/lib/session";
import { PageHead } from "../../page-head";
import StaffSection from "../staff/section";
import ContractorsSection from "../contractors/section";

/**
 * HR → People and HR → Contractors (21 Sept 2026; was Admin → People).
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
  searchParams: Promise<{ from?: string; to?: string; year?: string; tab?: string }>;
}) {
  await requireAdmin();
  // HR → People and HR → Contractors are this screen's two halves (21 Sept 2026).
  const contractors = (await searchParams).tab === "contractors";

  if (contractors) {
    return (
      <>
        <PageHead title="Contractors" context="Contractor profiles, payments as they were made, and what a 1099 needs" />
        <section id="contractors" className="page-section">
          <ContractorsSection searchParams={searchParams} />
        </section>
      </>
    );
  }

  return (
    <>
      <PageHead title="People" context="Staff: accounts, pay, onboarding, certifications and offboarding" />
      <section id="staff" className="page-section">
        <StaffSection searchParams={searchParams} />
      </section>
    </>
  );
}
