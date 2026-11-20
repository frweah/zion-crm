import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today, PRACTICE_TZ } from "@/lib/constants";
import { REPORT_TEMPLATES } from "@/lib/report-shape";
import { toReportBoardRows } from "@/lib/reports-board-shape";
import { PageHead } from "../page-head";
import { DataTable } from "../data-table";
import { ToFile, type ClientOption, type FileItem } from "../to-file";
import { ReportsBoard } from "./reports-board";

/**
 * Reports — the client-month board (owner, 20 November 2026).
 *
 * The practice had no reports screen. Nineteen October reports sat in Draft,
 * every one of them a fortnight past its date, and the question "which are
 * overdue and whose are they" could not be answered by anybody from any
 * screen: My day showed each person only their own with no overdue flag, the
 * administrator owned none and so saw none, and the practice-wide answer took
 * fifty-four taps through the client records and still did not say who was
 * writing them. docs/timing/reports.md is that survey, timed before this
 * screen existed.
 *
 * What is here: one row per client per month per report, built from the
 * caseload rather than from the table, so the current month has rows on the
 * 1st instead of on the 1st of the next. The To file panel sits above it
 * because an unfiled appointment is a line missing from the month underneath,
 * and for Reports and Admin it is everybody's panel rather than their own.
 *
 * Four things to look at, in one strip: this month, last month, what the five
 * reports are, and everything that has been sent. A strip of four is a choice
 * of what to show rather than a second row of tabs - the sidebar's tabs are
 * the only tabs, which is §11.
 */

type Tab = "board" | "templates" | "sent";

/** The first of a month, n months back from this one. */
function monthBack(from: string, n: number): string {
  const d = new Date(`${from.slice(0, 7)}-01T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() - n);
  return d.toISOString().slice(0, 10);
}

const monthName = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", {
    timeZone: PRACTICE_TZ,
    month: "long",
    year: "numeric",
  });

export default async function ReportsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; month?: string }>;
}) {
  const asked = await searchParams;
  const me = await requireStaff();
  const supabase = await createClient();

  const day = today();
  const thisMonth = monthBack(day, 0);
  const lastMonth = monthBack(day, 1);
  const tab: Tab =
    asked.tab === "templates" ? "templates" : asked.tab === "sent" ? "sent" : "board";
  // A month typed into the address that is not one of the two the strip
  // offers is read as this month rather than refused: the strip is a choice
  // of period and a period nobody offered is not a fault worth a screen.
  const period = asked.month === lastMonth ? lastMonth : thisMonth;

  // Reports and Admin see every inbox (ruling 2); everybody else sees their
  // own, which is what My day has always shown them. `to_file`'s read policy
  // says the same thing and says it last.
  const everybodys = ["Admin", "Reports"].includes(me.role);

  const [boardResult, staffResult, waitingResult, countResult, clientsResult, sentResult] =
    await Promise.all([
      tab === "board"
        ? supabase.rpc("report_board_rows", { p_period: period })
        : Promise.resolve({ data: [] as never[], error: null }),
      supabase
        .from("staff")
        .select("id, name")
        .eq("active", true)
        .eq("is_system", false)
        .order("name"),
      tab === "board"
        ? (() => {
            const q = supabase
              .from("to_file")
              /*
               * The foreign key is named, and has to be.
               *
               * `to_file` has three columns pointing at `staff` - whose inbox
               * it is, who the thing was actually with, and who decided it -
               * so `staff(name)` is ambiguous and PostgREST refuses the whole
               * query with PGRST201. That refusal arrives as `{ data: null }`,
               * which on this screen is indistinguishable from an empty
               * inbox: the panel would simply not be there, on every deploy,
               * and the smoke check would see HTTP 200 and agree.
               *
               * Whose inbox it is, which is what the panel groups by.
               */
              .select(
                "id, source, title, detail, happened_at, client_id, guess_why, clients(name), staff!to_file_staff_id_fkey(name)",
              )
              .eq("state", "Waiting")
              .order("happened_at", { ascending: false, nullsFirst: false })
              .limit(60);
            return everybodys ? q : q.eq("staff_id", me.id);
          })()
        : Promise.resolve({ data: [] as never[], error: null }),
      tab === "board"
        ? (() => {
            const q = supabase
              .from("to_file")
              .select("id", { count: "exact", head: true })
              .eq("state", "Waiting");
            return everybodys ? q : q.eq("staff_id", me.id);
          })()
        : Promise.resolve({ count: 0, error: null }),
      tab === "board"
        ? supabase.from("clients").select("id, name").is("merged_into", null).order("name").limit(2000)
        : Promise.resolve({ data: [] as { id: string; name: string }[], error: null }),
      tab === "sent"
        ? supabase
            .from("client_reports")
            .select("id, client_id, template, period, sent_at, sent_to, signed_at, clients(name)")
            .eq("status", "Sent")
            .order("sent_at", { ascending: false })
            .limit(200)
        : Promise.resolve({ data: [] as never[], error: null }),
    ]);

  const rows = toReportBoardRows(boardResult.data);
  const staff = staffResult.data ?? [];

  const toFile = ((waitingResult.data ?? []) as unknown as {
    id: string;
    source: string;
    title: string;
    detail: string;
    happened_at: string | null;
    client_id: string | null;
    guess_why: string;
    clients: { name: string } | null;
    staff: { name: string } | null;
  }[]).map<FileItem>((f) => ({
    id: f.id,
    source: f.source,
    title: f.title,
    detail: f.detail,
    happened_at: f.happened_at,
    client_id: f.client_id,
    client_name: f.clients?.name ?? null,
    guess_why: f.guess_why,
    staff_name: f.staff?.name ?? null,
  }));
  const clientOptions: ClientOption[] = (clientsResult.data ?? []) as ClientOption[];

  const strip: [string, string][] = [
    [`/reports?month=${thisMonth}`, monthName(thisMonth)],
    [`/reports?month=${lastMonth}`, monthName(lastMonth)],
    ["/client-reports?tab=templates", "Templates"],
    ["/client-reports?tab=sent", "Sent log"],
  ];
  const here =
    tab === "templates"
      ? "/client-reports?tab=templates"
      : tab === "sent"
        ? "/client-reports?tab=sent"
        : `/reports?month=${period}`;

  const owed = rows.filter((r) => r.owed).length;

  return (
    <>
      <PageHead
        title="Reports"
        context={
          tab === "board" ? (
            <>
              {monthName(period)} — {owed} owed, {rows.length - owed} offered
            </>
          ) : tab === "templates" ? (
            <>The five the practice sends</>
          ) : (
            <>Every report that has gone to a counselor</>
          )
        }
      />

      <div className="segmented" role="group" aria-label="What to show" style={{ marginBottom: 12 }}>
        {strip.map(([href, label]) => (
          <Link key={href} href={href} className={href === here ? "on" : undefined}>
            {label}
          </Link>
        ))}
      </div>

      {/*
        A read that failed is not an empty month.

        The To file panel is drawn only when it has items and the board's
        empty state says the caseload is empty, so a query that came back
        refused reads on screen as "there is nothing" - which is how the
        ambiguous `staff(name)` embed shipped and would have stayed shipped.
        Whatever the database refused is said here in its own words, above
        whatever did arrive.
      */}
      {tab === "board" && (boardResult.error || waitingResult.error) && (
        <p className="alert bad">
          {boardResult.error?.message ?? waitingResult.error?.message}
        </p>
      )}

      {tab === "board" && (
        <>
          <ToFile
            items={toFile}
            clients={clientOptions}
            waiting={countResult.count ?? toFile.length}
            anchor="to-file"
            grouped={everybodys}
            foldable
          />

          <ReportsBoard
            rows={rows}
            staff={staff}
            today={day}
            me={{ id: me.id, role: me.role }}
            toFileWaiting={countResult.count ?? toFile.length}
          />
        </>
      )}

      {tab === "templates" && (
        <section className="page-section">
          <h2 className="h2">Templates</h2>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="templates"
              columns={[
                { key: "name", label: "Report" },
                { key: "every", label: "Period", width: 110 },
                { key: "carries", label: "What it carries" },
                { key: "board", label: "On the board" },
              ]}
              rows={REPORT_TEMPLATES.map((t) => ({
                key: t.key,
                sort: { name: t.key, every: t.every },
                cells: {
                  name: <b>{t.key}</b>,
                  every: t.every === "week" ? "a week" : "a month",
                  carries: t.note,
                  board:
                    t.every === "week"
                      ? "no — a week is not a month"
                      : t.key === "Monthly client report"
                        ? "every client, every month"
                        : t.key === "Job search report"
                          ? "once somebody assembles one"
                          : "where the service is authorized",
                },
              }))}
              empty="No template is set up."
            />
          </div>
        </section>
      )}

      {tab === "sent" && (
        <section className="page-section">
          <h2 className="h2">Sent log</h2>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="sent reports"
              columns={[
                { key: "sent", label: "Sent", width: 120 },
                { key: "client", label: "Client" },
                { key: "report", label: "Report" },
                { key: "month", label: "Month", width: 130 },
                { key: "to", label: "Sent to" },
              ]}
              rows={((sentResult.data ?? []) as unknown as {
                id: string;
                client_id: string;
                template: string;
                period: string;
                sent_at: string | null;
                sent_to: string | null;
                clients: { name: string } | null;
              }[]).map((r) => ({
                key: r.id,
                sort: {
                  sent: r.sent_at ?? "",
                  client: r.clients?.name ?? "",
                  report: r.template,
                  month: r.period,
                },
                text: `${r.clients?.name ?? ""} ${r.template} ${r.sent_to ?? ""}`,
                cells: {
                  sent: r.sent_at
                    ? new Date(r.sent_at).toLocaleDateString("en-US", {
                        timeZone: PRACTICE_TZ,
                        month: "short",
                        day: "numeric",
                        year: "numeric",
                      })
                    : "",
                  client: (
                    <Link href={`/clients/${r.client_id}?tab=dashboard`}>
                      {r.clients?.name ?? "—"}
                    </Link>
                  ),
                  report: r.template,
                  month: (
                    <Link
                      href={`/clients/${r.client_id}/reports/${r.period.slice(0, 7)}?template=${encodeURIComponent(r.template)}`}
                    >
                      {monthName(r.period)}
                    </Link>
                  ),
                  to: <span className="lock">{r.sent_to || "—"}</span>,
                },
              }))}
              empty="Nothing has been sent yet — sign a report and the Signed pill mails it."
            />
          </div>
        </section>
      )}
    </>
  );
}
