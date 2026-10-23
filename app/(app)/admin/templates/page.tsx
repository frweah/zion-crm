import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { PageHead } from "../../page-head";
import { NoticeRecipientForm, SignatureForm, TemplateForm } from "./forms";

/**
 * Templates (owner, 23 Oct 2026).
 *
 * The letters the practice keeps writing, and the two settings that go with
 * them: what every message is signed with, and who hears about a reply that
 * filed itself.
 *
 * Note and text templates are not here. They are edited where they are used -
 * Admin → Settings → Notes, and the client's Messages tab - and moving them
 * would be a change the owner has not asked for. This screen is the mail
 * ones.
 */
const FIELDS = [
  "{client}",
  "{client_no}",
  "{counselor}",
  "{authorization}",
  "{service}",
  "{issued}",
  "{ends}",
  "{me}",
  "{signature}",
];

export default async function TemplatesPage() {
  const me = await getCurrentStaff();
  if (!me) redirect("/sign-in");
  if (me.role !== "Admin") redirect("/dashboard");

  const supabase = await createClient();
  const [{ data: templates }, { data: settings }, { data: staff }] = await Promise.all([
    supabase.from("mail_templates").select("key, label, subject, body, active").order("sort_order"),
    supabase.from("org_settings").select("mail_signature, mail_notice_staff_id").maybeSingle(),
    supabase.from("staff").select("id, name, role").eq("active", true).order("name"),
  ]);

  return (
    <>
      <PageHead title="Templates" context="The letters the practice keeps writing" />

      {(templates ?? []).map((t) => (
        <TemplateForm
          key={t.key}
          template={{
            key: t.key,
            label: t.label,
            subject: t.subject,
            body: t.body,
            active: t.active,
          }}
          fields={FIELDS}
        />
      ))}

      <h2 className="h2">Signature</h2>
      <SignatureForm signature={settings?.mail_signature ?? ""} />

      <h2 className="h2">Replies</h2>
      <NoticeRecipientForm staff={staff ?? []} current={settings?.mail_notice_staff_id ?? null} />
    </>
  );
}
