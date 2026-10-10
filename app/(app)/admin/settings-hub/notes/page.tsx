import { requireAdmin } from "@/lib/session";
import { RecordHeader } from "../../../record-header";
import NoteTemplatesSection from "../../note-templates/section";

/** What a note starts with, by kind (Design language, §3). */
export default async function NoteSettings() {
  await requireAdmin();
  return (
    <>
      <RecordHeader
        back={{ href: "/admin/settings-hub", label: "Settings" }}
        title="Note headings"
        standing="What a note starts with, by kind"
      />
      <NoteTemplatesSection />
    </>
  );
}
