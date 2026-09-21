import "server-only";
import { createClient } from "@/lib/supabase/server";
import { sendEmail, emailConfigured } from "@/lib/email";
import { ORG } from "@/lib/roles";

/**
 * Marks the walkthrough finished when the six are done, and emails Admin the
 * once. The database decides both; refresh_onboarding says true only the
 * first time. Called from the page, so a step finished elsewhere - the tax
 * form on Paperwork, say - counts too.
 */
export async function finishIfDone(staffId: string, name: string): Promise<boolean> {
  const supabase = await createClient();
  const { data: finished } = await supabase.rpc("refresh_onboarding", { p_staff: staffId });
  if (!finished) return false;

  if (emailConfigured()) {
    const { data: admins } = await supabase.from("staff").select("email").eq("role", "Admin").eq("active", true).eq("is_system", false);
    const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
    const { data: i9 } = await supabase
      .from("staff_documents")
      .select("id")
      .eq("staff_id", staffId)
      .eq("inspection_required", true)
      .limit(1);
    for (const a of admins ?? []) {
      if (!a.email) continue;
      await sendEmail({
        to: a.email,
        subject: `${name} finished onboarding`,
        text: [
          `${name} has completed all six onboarding steps in the CRM.`,
          "",
          ...(i9?.length
            ? ["Their I-9 documents still need inspecting in person - originals in hand - and recording on their file.", ""]
            : []),
          "Still yours: any certification they put forward needs checking against the scan, and the rate and",
          "the rest of the checklist are on their record.",
          "",
          `${site}/admin/people/${staffId}`,
          "",
          ORG.name,
        ].join("\n"),
      });
    }
  }
  return true;
}
