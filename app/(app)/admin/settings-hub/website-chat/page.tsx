import Link from "next/link";
import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { RecordHeader } from "../../../record-header";
import { WebChatSettingsForm, type WebChatSettings } from "../../system/web-chat";

/**
 * Who takes the website chat, and when (Design language, §3).
 *
 * Its own page, because changing who answers the bubble should not mean
 * scrolling past the tax years.
 */
export default async function WebsiteChatSettings() {
  await requireAdmin();
  const supabase = await createClient();

  const [{ data: staff }, { data: webChat, error: failure }, { data: live }] = await Promise.all([
    supabase.from("staff").select("id, name").eq("active", true).eq("is_system", false).order("name"),
    supabase
      .from("org_settings")
      .select("web_chat_enabled, web_chat_takers, web_chat_open, web_chat_close, web_chat_days, web_chat_greeting, web_chat_promise")
      .maybeSingle(),
    supabase.rpc("web_chat_live"),
  ]);

  // A refused read arrives as an empty row rather than as nothing, so it is
  // said out loud: defaults shown as if they were the practice's settings
  // would be a screen quietly lying.
  const chat = (webChat ?? {
    web_chat_enabled: false,
    web_chat_takers: [],
    web_chat_open: "09:00",
    web_chat_close: "17:00",
    web_chat_days: [1, 2, 3, 4, 5],
    web_chat_greeting: "",
    web_chat_promise: "",
  }) as WebChatSettings;

  return (
    <>
      <RecordHeader
        back={{ href: "/admin/settings-hub", label: "Settings" }}
        title="Website chat"
        standing="Who takes it, when it is offered, and what it says"
      />
      <p className="sub">
        The bubble on zionrehabcenter.com. What somebody says there arrives in{" "}
        <Link href="/messages/texts?tab=web">Website chat</Link>, beside the texts, and joins a client&apos;s record as
        soon as it is matched to one.
      </p>
      {failure && (
        <div className="alert bad">
          These settings could not be read ({failure.message}), so what is shown is not what is saved. Do not save over
          them until that is fixed.
        </div>
      )}
      <WebChatSettingsForm
        settings={chat}
        staff={staff ?? []}
        live={Boolean(live)}
        embed={`<script src="${process.env.NEXT_PUBLIC_SITE_URL ?? "https://crm.zionvocrehab.com"}/widget.js" async></script>`}
      />
    </>
  );
}
