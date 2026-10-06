import { requireAdmin } from "@/lib/session";
import { PageHead } from "../../../page-head";
import NoteTemplatesSection from "../../note-templates/section";

/** What a note starts with, by kind (Design language, §3). */
export default async function NoteSettings() {
  await requireAdmin();
  return (
    <>
      <PageHead title="Note headings" context="What a note starts with, by kind" />
      <NoteTemplatesSection />
    </>
  );
}
