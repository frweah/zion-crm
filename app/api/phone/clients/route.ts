import { type NextRequest } from "next/server";
import { phoneStaff, fresh } from "@/lib/phone/server";

/**
 * Finding a client from the phone: your own first, then anybody by name.
 *
 * Names and ids only. What is on a client is asked for when one is opened,
 * which is also what decides what the phone may keep.
 */
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const who = await phoneStaff();
  if ("response" in who) return who.response;
  const { staff: me, supabase } = who;
  const q = (request.nextUrl.searchParams.get("q") ?? "").trim().replace(/[%,()]/g, " ").slice(0, 60);

  const query = supabase.from("clients").select("id, name, stage").is("merged_into", null).order("name").limit(25);
  const { data, error } = q
    ? await query.ilike("name", `%${q}%`)
    : await query.or(`assigned_staff_id.eq.${me.id},billing_staff_id.eq.${me.id}`).eq("status", "Active");
  if (error) return fresh({ error: error.message }, 503);
  return fresh({ clients: data ?? [], mine: !q });
}
