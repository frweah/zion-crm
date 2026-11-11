import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { CAN_EDIT_CLIENTS } from "@/lib/constants";
import { PhoneApp } from "./phone-app";

/**
 * /phone - where the installed app opens.
 *
 * The page carries only who is holding the phone. Everything on it is read
 * by the screen itself from /api/phone, and kept, so that the same page
 * opens with no signal (public/sw.js keeps the page; lib/phone/store.ts
 * keeps the answers).
 */
export const dynamic = "force-dynamic";

export default async function PhonePage() {
  const me = await requireStaff();
  const supabase = await createClient();
  const { data: answered } = await supabase
    .from("staff_prefs")
    .select("key")
    .eq("key", "hint:install-app")
    .maybeSingle();
  return (
    <PhoneApp
      me={{ id: me.id, name: me.name, role: me.role }}
      canNote={CAN_EDIT_CLIENTS.includes(me.role)}
      installAnswered={Boolean(answered)}
    />
  );
}
