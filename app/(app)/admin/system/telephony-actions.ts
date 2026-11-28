"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Which carrier the client line runs on (owner, 27 November 2026).
 *
 * Admin's to set, and the row rule on `org_settings` says so rather than this
 * file. The reason it is a setting at all is that the day the number moves,
 * somebody has to be able to put it back inside a minute without waiting
 * twenty for a build.
 */
export type TelephonyState = { error: string | null; ok: string | null };

const KNOWN = ["ghl", "twilio"] as const;
type Known = (typeof KNOWN)[number];

/** Whose desk the line rings (owner, 27 Nov 2026). */
const MODES = ["off", "admin", "all"] as const;
type Mode = (typeof MODES)[number];

export async function saveTelephony(
  _prev: TelephonyState,
  formData: FormData,
): Promise<TelephonyState> {
  const chosen = String(formData.get("provider") ?? "");
  if (!KNOWN.includes(chosen as Known)) {
    return { error: "Choose GoHighLevel or Twilio.", ok: null };
  }

  /**
   * The keys are checked before the switch moves, not after.
   *
   * This is the whole value of the screen. Moving the line to a carrier whose
   * API key is not in the environment yet would leave every text failing with
   * a sentence about a missing variable, and the client line is not the place
   * to find that out. The same question `lib/text-provider.ts` asks before a
   * sweep walks a list, asked here before anybody can cause it.
   */
  if (chosen === "twilio") {
    const missing = (
      [
        ["TWILIO_ACCOUNT_SID", process.env.TWILIO_ACCOUNT_SID],
        ["TWILIO_API_KEY_SID", process.env.TWILIO_API_KEY_SID],
        ["TWILIO_API_KEY_SECRET", process.env.TWILIO_API_KEY_SECRET],
        ["TWILIO_MESSAGING_SERVICE_SID", process.env.TWILIO_MESSAGING_SERVICE_SID],
        ["TWILIO_AUTH_TOKEN", process.env.TWILIO_AUTH_TOKEN],
      ] as const
    )
      .filter(([, value]) => !value)
      .map(([name]) => name);
    if (missing.length > 0) {
      return {
        error: `Twilio is missing ${missing.join(", ")} — add them in Vercel, redeploy, then move the line.`,
        ok: null,
      };
    }
  }

  if (chosen === "ghl" && !(process.env.GHL_API_KEY && process.env.GHL_LOCATION_ID)) {
    return {
      error: "GoHighLevel is missing GHL_API_KEY or GHL_LOCATION_ID, so nothing could be sent through it.",
      ok: null,
    };
  }

  const voice = String(formData.get("voice") ?? "");
  if (!MODES.includes(voice as Mode)) {
    return { error: "Choose who the line rings.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase
    .from("org_settings")
    .update({ sms_provider: chosen, voice_mode: voice })
    .eq("id", true);

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/system");

  /**
   * Said as one sentence, because it is one decision: which carrier, and
   * whose desk hears it. A screen that reported only half of what the button
   * changed would be a screen somebody has to press twice to believe.
   */
  const rings =
    voice === "all"
      ? "every seat that texts clients"
      : voice === "admin"
        ? "Admin seats only"
        : "nobody";

  return {
    error: null,
    ok:
      (chosen === "twilio"
        ? "The line is on Twilio and rings "
        : "The line is on GoHighLevel and rings ") +
      rings +
      (chosen === "twilio" ? ". Send one text and make one call before telling anybody." : "."),
  };
}
