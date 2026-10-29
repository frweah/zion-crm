import Link from "next/link";
import { notFound } from "next/navigation";
import { RecordHeader } from "../../../record-header";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { DataTable } from "../../../data-table";
import { WeekCard, type WeekRow } from "./week-card";
import { MakeWeek } from "./make-week";
import { MakeMonth } from "./make-month";

/**
 * One client's reports.
 *
 * The weeks first, because the week is the thing somebody does something
 * about: it is drafted on the Monday, it is confirmed by whoever did the
 * work, and by the 1st the month is four of them rather than a month of
 * recall. The months are underneath as a list, which is all they are until
 * one is opened to be signed and sent.
 *
 * Reached from the client record's Documents tab rather than from an eighth
 * tab: a record with more than six tabs is two records, and this is a screen
 * in its own right with a table and a card list on it.
 */
export default async function ClientReportsPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const me = await requireStaff();
  const supabase = await createClient();

  const { data: client } = await supabase
    .from("clients")
    .select("id, name, client_no, status, assigned_staff_id")
    .eq("id", id)
    .maybeSingle();
  if (!client) notFound();

  const [{ data: weekRows }, { data: monthRows }] = await Promise.all([
    supabase
      .from("client_weekly_reports")
      .select("id, week_start, status, due_on, note, content, confirmed_by")
      .eq("client_id", id)
      .order("week_start", { ascending: false })
      .limit(10),
    supabase
      .from("client_monthly_reports")
      .select("id, month, status, due_on, signed_at, sent_at, sent_to, content")
      .eq("client_id", id)
      .order("month", { ascending: false })
      .limit(12),
  ]);

  const weeks = weekRows ?? [];
  const months = monthRows ?? [];

  const whoIds = [...new Set(weeks.map((w) => w.confirmed_by).filter(Boolean))] as string[];
  const { data: staffRows } = whoIds.length
    ? await supabase.from("staff").select("id, name").in("id", whoIds)
    : { data: [] as { id: string; name: string }[] };
  const nameOf = new Map((staffRows ?? []).map((s) => [s.id, s.name] as const));

  // Admin, or the person whose client it is. The database says the same thing
  // (0260) and says it last; this is so the buttons are not offered to
  // somebody they would refuse.
  const canEdit = me.role === "Admin" || client.assigned_staff_id === me.id;

  // The week just gone, and whether it was drafted. A client taken on after
  // Monday has no row for it and the scheduler will not go back.
  const now = today();
  const monday = new Date(`${now}T00:00:00Z`);
  monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7) - 7);
  const lastWeek = monday.toISOString().slice(0, 10);
  const missing =
    ["Active", "On hold"].includes(client.status) &&
    !weeks.some((w) => w.week_start === lastWeek);

  // The same question for the month. The scheduler assembles it on the 1st
  // and does not go back, so a client taken on mid-month has no row for the
  // month they were taken on in.
  const first = new Date(`${now.slice(0, 7)}-01T00:00:00Z`);
  first.setUTCMonth(first.getUTCMonth() - 1);
  const lastMonth = first.toISOString().slice(0, 10);
  const monthMissing =
    ["Active", "On hold"].includes(client.status) &&
    !months.some((m) => m.month === lastMonth);

  return (
    <>
      <RecordHeader
        back={{ href: `/clients/${id}?tab=documents`, label: `${client.name} · Documents` }}
        title="Reports"
        identity={[client.name, client.client_no ? `Client #${client.client_no}` : null]}
        standing={<span className="chip">{client.status}</span>}
      />

      <section className="page-section">
        <h2 className="h2">Weeks</h2>
        {missing && canEdit && <MakeWeek clientId={id} weekStart={lastWeek} />}
        {weeks.length === 0 ? (
          <p className="empty">
            No week has been drafted yet — the next one is drafted on Monday morning.
          </p>
        ) : (
          weeks.map((w) => (
            <WeekCard
              key={w.id}
              clientId={id}
              canEdit={canEdit}
              week={
                {
                  ...w,
                  note: w.note ?? "",
                  confirmed_by_name: w.confirmed_by ? (nameOf.get(w.confirmed_by) ?? "") : "",
                } as unknown as WeekRow
              }
            />
          ))
        )}
      </section>

      <section className="page-section">
        <h2 className="h2">Months</h2>
        {monthMissing && canEdit && <MakeMonth clientId={id} month={lastMonth} />}
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="monthly reports"
            columns={[
              { key: "month", label: "Month", width: 120 },
              { key: "status", label: "Status", width: 110 },
              { key: "weeks", label: "Weeks" },
              { key: "due", label: "Due", width: 110 },
              { key: "sent", label: "Sent to" },
            ]}
            rows={months.map((m) => {
              const content = (m.content ?? {}) as {
                weeks?: { status: string }[];
                gaps?: unknown[];
              };
              const held = content.weeks ?? [];
              const sure = held.filter((w) => w.status === "Confirmed").length;
              const gaps = (content.gaps ?? []).length;
              return {
                key: m.id,
                sort: { month: m.month, status: m.status, weeks: sure, due: m.due_on, sent: m.sent_to },
                text: `${m.month} ${m.status} ${m.sent_to}`,
                cells: {
                  month: (
                    <Link href={`/clients/${id}/reports/${m.month.slice(0, 7)}`}>
                      {new Date(`${m.month}T12:00:00Z`).toLocaleDateString("en-US", {
                        month: "long",
                        year: "numeric",
                      })}
                    </Link>
                  ),
                  status: (
                    <span
                      className={
                        "chip " +
                        (m.status === "Sent"
                          ? "ok"
                          : m.status === "Signed"
                            ? "gold"
                            : m.due_on < now
                              ? "warn"
                              : "")
                      }
                    >
                      {m.status}
                    </span>
                  ),
                  weeks: (
                    <span className="lock">
                      {sure} of {held.length} confirmed
                      {gaps > 0 && `, ${gaps} stretch${gaps === 1 ? "" : "es"} nobody saw`}
                    </span>
                  ),
                  due: m.due_on,
                  sent: <span className="lock">{m.sent_to || "—"}</span>,
                },
              };
            })}
            empty="No month has been assembled yet — the first is drafted on the 1st."
          />
        </div>
      </section>
    </>
  );
}
