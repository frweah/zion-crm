import type { Metadata } from "next";
import { requirePortal } from "@/lib/portal/session";
import { createClient } from "@/lib/supabase/server";
import { cleanResume, emptyResume } from "@/lib/portal/resume";
import { ResumeView } from "../_components/views";

export const metadata: Metadata = { title: "Resume" };
export const dynamic = "force-dynamic";

export default async function PortalResumePage() {
  const me = await requirePortal();
  const supabase = await createClient();
  const { data } = await supabase.rpc("portal_my_resume");
  const row = (data ?? [])[0];
  const status = (row?.status ?? "None") as "None" | "Draft" | "Returned" | "Submitted" | "Approved";

  // A first visit starts from what the record already knows. Nothing else is
  // filled in for them.
  let resume = cleanResume(row?.data ?? {});
  if (status === "None") {
    resume = emptyResume();
    resume.contact = {
      name: row?.record_name ?? "",
      phone: row?.record_phone ?? "",
      email: row?.record_email ?? "",
      city: row?.record_city ?? "",
    };
  }
  return <ResumeView me={me} resume={resume} step={row?.step ?? 0} status={status} returnNote={row?.return_note ?? ""} />;
}
