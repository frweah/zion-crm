import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ROLE_NAMES, ROLE_LABEL } from "@/lib/roles";
import { fmtStamp } from "@/lib/constants";
import { PageHead } from "../page-head";
import { UpdateFeed, PostUpdate, type UpdateRow } from "./updates-view";

/**
 * Updates: what the practice tells everybody (Design language, §3).
 *
 * A feed, not a table - it reads top-down like the messaging app it stands in
 * for. What is pinned and unread sits at the top; everything else is in the
 * order it was posted.
 *
 * Admin sees one thing more: how many have read each post, and who has not.
 * That list is the reason the feature exists - an email read receipt is a
 * setting people turn off, and a text to seven people is seven conversations.
 */
export default async function UpdatesPage() {
  const me = await requireStaff();
  const supabase = await createClient();
  const isAdmin = me.role === "Admin";

  const [{ data: rows }, { data: staff }, { data: reads }] = await Promise.all([
    supabase.from("updates_for_me").select("*").order("posted_at", { ascending: false }),
    isAdmin
      ? supabase.from("staff").select("id, name, role").eq("active", true).eq("is_system", false).order("name")
      : Promise.resolve({ data: [] as { id: string; name: string; role: string }[] }),
    isAdmin
      ? supabase.from("update_reads").select("update_id, staff_id")
      : Promise.resolve({ data: [] as { update_id: string; staff_id: string }[] }),
  ]);

  const updates = ((rows ?? []) as unknown as UpdateRow[]).sort((a, b) => {
    // Pinned and not yet read by this person comes first; that is what
    // "pinned until read" means.
    const weight = (u: UpdateRow) => (u.pinned && !u.read_by_me ? 0 : 1);
    return weight(a) - weight(b) || (b.posted_at ?? "").localeCompare(a.posted_at ?? "");
  });

  // Who has not read each one, for the person who has to chase it.
  const notRead = new Map<string, string[]>();
  if (isAdmin) {
    const byUpdate = new Map<string, Set<string>>();
    for (const r of reads ?? []) {
      if (!byUpdate.has(r.update_id)) byUpdate.set(r.update_id, new Set());
      byUpdate.get(r.update_id)!.add(r.staff_id);
    }
    for (const u of updates) {
      const seen = byUpdate.get(u.id) ?? new Set<string>();
      const audience = (staff ?? []).filter(
        (s) => (u.audience ?? []).length === 0 || (u.audience ?? []).includes(s.role),
      );
      notRead.set(
        u.id,
        audience.filter((s) => !seen.has(s.id)).map((s) => s.name),
      );
    }
  }

  return (
    <>
      <PageHead
        title="Updates"
        context={isAdmin ? "What the practice tells everybody, and who has read it" : "What the practice tells everybody"}
      />

      {isAdmin && <PostUpdate roles={ROLE_NAMES.map((r) => ({ key: r, label: ROLE_LABEL[r] }))} />}

      <UpdateFeed
        updates={updates.map((u) => ({
          ...u,
          posted_when: u.posted_at ? fmtStamp(u.posted_at) : "",
          not_read: notRead.get(u.id) ?? null,
        }))}
        isAdmin={isAdmin}
      />
    </>
  );
}
