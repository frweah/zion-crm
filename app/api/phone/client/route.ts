import { type NextRequest } from "next/server";
import { phoneStaff, fresh } from "@/lib/phone/server";
import { categoryForStage, NOTE_CATEGORIES } from "@/lib/report-shape";
import { stageLabel } from "@/lib/constants";

/**
 * One client, as the phone shows them: who, how to reach them, where they
 * are, who sent them, and the last three things written - and nothing else
 * (owner, 11 Nov 2026). Everything else is on the full record, a link away.
 *
 * Read through the person's own session, so a note they may not see is not
 * here either: the notes table's own rules decide, as they do on the record.
 *
 * The phone keeps this for the rest of the day so a client opened this
 * morning can be opened again with no signal, and throws it away at
 * midnight. Nothing restricted is in it: no documents, no diagnosis, no ID.
 */
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const who = await phoneStaff();
  if ("response" in who) return who.response;
  const { supabase } = who;
  const id = request.nextUrl.searchParams.get("id") ?? "";
  if (!/^[0-9a-f-]{36}$/i.test(id)) return fresh({ error: "Which client?" }, 400);

  const [client, counselor, notes, fileCategories, canRestrict] = await Promise.all([
    supabase.from("clients").select("id, name, phone, stage, status").eq("id", id).maybeSingle(),
    supabase
      .from("clients")
      .select("counselor:counselors!clients_counselor_id_fkey(name, phone)")
      .eq("id", id)
      .maybeSingle() as unknown as Promise<{ data: { counselor: { name: string; phone: string | null } | null } | null }>,
    supabase
      .from("notes")
      .select("id, text, type, staff_name, ts")
      .eq("client_id", id)
      .order("ts", { ascending: false })
      .limit(3),
    supabase
      .from("client_file_categories")
      .select("key, label, restricted_by_default")
      .eq("active", true)
      .order("sort_order"),
    supabase.rpc("clients_i_can_restrict"),
  ]);

  if (client.error) return fresh({ error: client.error.message }, 503);
  if (!client.data) return fresh({ error: "That client is not open to you." }, 404);

  const stage = client.data.stage ?? "";
  return fresh({
    id: client.data.id,
    name: client.data.name,
    phone: client.data.phone ?? "",
    stage: stage ? stageLabel(stage) : "",
    status: client.data.status,
    counselor: counselor.data?.counselor?.name ?? "",
    counselorPhone: counselor.data?.counselor?.phone ?? "",
    notes: (notes.data ?? []).map((n) => ({ id: n.id, text: n.text, type: n.type, by: n.staff_name, at: n.ts })),
    noteCategory: categoryForStage(stage),
    noteCategories: [...NOTE_CATEGORIES],
    fileCategories: fileCategories.data ?? [],
    canRestrict: ((canRestrict.data ?? []) as unknown as string[]).includes(id),
    fetchedAt: new Date().toISOString(),
  });
}
