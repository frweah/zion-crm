"use server";

import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type PersonalDetails = {
  legal_name: string;
  address: string;
  phone: string;
  date_of_birth: string | null;
  emergency: string;
};

export type RevealState = { error: string | null; details: PersonalDetails | null };

/**
 * Somebody's personal details, for Admin, on request. Opening them is written
 * to the access log first (0100) - the database refuses to say yes without
 * writing down that it did - and only then are they read.
 */
export async function revealPersonalDetails(_prev: RevealState, formData: FormData): Promise<RevealState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin opens somebody's personal details.", details: null };

  const staffId = String(formData.get("staff_id") ?? "");
  const supabase = await createClient();
  const { data: allowed, error: logError } = await supabase.rpc("note_staff_personal_access", { p_staff: staffId });
  if (logError || !allowed) return { error: logError?.message ?? "Not allowed.", details: null };

  const { data: p } = await supabase.from("staff_personal").select("*").eq("staff_id", staffId).maybeSingle();
  if (!p) return { error: "Nothing is on file yet.", details: null };

  return {
    error: null,
    details: {
      legal_name: p.legal_name,
      address: [p.address_line1, p.address_line2, [p.city, p.state].filter(Boolean).join(", "), p.postal_code]
        .filter(Boolean)
        .join(", "),
      phone: p.phone,
      date_of_birth: p.date_of_birth,
      emergency: [p.emergency_name, p.emergency_relationship && `(${p.emergency_relationship})`, p.emergency_phone]
        .filter(Boolean)
        .join(" "),
    },
  };
}
