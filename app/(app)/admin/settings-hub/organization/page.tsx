import { requireAdmin } from "@/lib/session";
import { PageHead } from "../../../page-head";
import SettingsSection from "../../settings/section";

/** Who the practice is, on a page of its own (Design language, §3). */
export default async function OrganizationSettings() {
  await requireAdmin();
  return (
    <>
      <PageHead title="The practice" context="Legal name, address, EIN — what appears on a form" />
      <SettingsSection />
    </>
  );
}
