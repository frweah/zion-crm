import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { NEEDS, loadNeed, countNeeds, type NeedKey } from "@/lib/needs";

/**
 * The list behind a dashboard counter.
 *
 * Counter and list come from the same function, so a number can never disagree
 * with what it opens — which is how this sort of dashboard usually goes wrong,
 * and how it stops being believed.
 */
export default async function NeedsPage({
  searchParams,
}: {
  searchParams: Promise<{ list?: string }>;
}) {
  const me = await requireStaff();
  const supabase = await createClient();

  const params = await searchParams;
  const key = (NEEDS.find((n) => n.key === params.list)?.key ?? "tasks") as NeedKey;

  const [rows, counts] = await Promise.all([
    loadNeed(supabase, key, me),
    countNeeds(supabase, me),
  ]);

  const active = NEEDS.find((n) => n.key === key)!;

  const explain: Record<NeedKey, string> = {
    tasks: "Open tasks due today or already past.",
    interviews: "Interviews in the next seven days, from the job tracker.",
    followups: "Follow-up dates that have arrived or passed.",
    inactive:
      "Active clients with nothing recorded for thirty days — no note, call, form, appointment, logged email, job or hours.",
    paperwork:
      "Clients where hours are logged against an open authorization and a USOR form that gates the invoice is not done.",
  };

  return (
    <>
      <h1 className="h1">Needs attention</h1>
      <p className="sub">
        {me.role === "Admin" ? "Across everybody." : "Yours."} {explain[key]}
      </p>

      <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 14 }}>
        {NEEDS.map((n) => (
          <Link
            key={n.key}
            href={`/needs?list=${n.key}`}
            className={"chip" + (n.key === key ? " gold" : "")}
            style={{ textDecoration: "none" }}
          >
            {n.label} {counts[n.key]}
          </Link>
        ))}
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table className="t">
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td className="empty">Nothing here — {active.label.toLowerCase()} is clear.</td>
              </tr>
            )}
            {rows.map((r) => (
              <tr key={`${key}-${r.id}`}>
                <td>
                  <Link href={r.href} style={{ fontWeight: 600 }}>
                    {r.title}
                  </Link>
                  <div style={{ fontSize: 12, color: "var(--muted)" }}>{r.detail}</div>
                </td>
                <td style={{ textAlign: "right", whiteSpace: "nowrap", color: "var(--muted)" }}>
                  {r.when ?? ""}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
