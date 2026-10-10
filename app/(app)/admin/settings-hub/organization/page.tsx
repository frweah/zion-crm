import { requireAdmin } from "@/lib/session";
import { RecordHeader } from "../../../record-header";
import SettingsSection from "../../settings/section";

/** Who the practice is, on a page of its own (Design language, §3). */
export default async function OrganizationSettings() {
  await requireAdmin();
  return (
    <>
      <RecordHeader
        back={{ href: "/admin/settings-hub", label: "Settings" }}
        title="The practice"
        standing="Legal name, address, EIN — what appears on a form"
      />
      <SettingsSection />
    </>
  );
}
