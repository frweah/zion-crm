import { money } from "@/lib/constants";
import { readSettings, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { DataTable, type DataRow } from "../../data-table";
import { PageHead } from "../../page-head";
import { ForecastSettings } from "./forecast-settings";

/**
 * What is expected to happen (ERP brief, E2).
 *
 * Three bands on the revenue side, kept apart on purpose: work already in the
 * pipeline, money authorized and not yet earned, and an estimate from the
 * referral trend. A single number blending those three degrees of certainty
 * is a number nobody can act on, and the month it matters is the month
 * somebody would have wanted to know which part was which.
 *
 * Nothing on this screen is stored. Every figure is worked out when the page
 * opens, from postings, authorizations and items - so a forecast cannot go
 * stale in a table somebody forgot to refresh.
 */
const month = (iso: string) =>
  new Date(iso + "T00:00:00Z").toLocaleDateString("en-US", {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });

const week = (iso: string) =>
  new Date(iso + "T00:00:00Z").toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });

export default async function Forecast() {
  await requireBooks();
  const me = await requireStaff();
  const supabase = await createClient();

  const [settings, { data: revenue }, { data: cost }, { data: cash }, { data: lag }] =
    await Promise.all([
      readSettings(supabase),
      supabase.rpc("ledger_revenue_forecast", { p_months: 3 }),
      supabase.rpc("ledger_cost_forecast", { p_months: 3 }),
      supabase.rpc("ledger_cash_forecast", { p_days: 90 }),
      supabase.rpc("ledger_payment_lag"),
    ]);

  const bands = (rows: { month: string; band: string; amount: number; note: string }[] | null) =>
    (rows ?? []).map((r, i): DataRow => ({
      key: `${r.month}-${r.band}-${i}`,
      cells: {
        month: month(r.month),
        band: r.band,
        amount: money(r.amount),
        note: r.note,
      },
      sort: { month: r.month, amount: r.amount },
    }));

  const weeks = (cash ?? []) as {
    week: string;
    opening: number;
    expected_in: number;
    expected_out: number;
    closing: number;
  }[];
  const floor = settings?.cash_floor ?? null;
  const dips = floor !== null ? weeks.find((w) => Number(w.closing) < Number(floor)) : undefined;

  return (
    <>
      <PageHead
        title="Forecast"
        context={`Ninety days, on what USOR has taken ${lag ?? 30} days to pay`}
      />

      {dips && (
        <p className="alert bad">
          The cash forecast drops to {money(dips.closing)} in the week of {week(dips.week)}, below
          the {money(Number(floor))} floor.
        </p>
      )}

      <h2 className="h2">Cash, by week</h2>
      {weeks.length === 0 && settings && (
        <p className="empty">
          Nothing until the books open on {settings.books_start} — no postings is not the same as no
          money.
        </p>
      )}
      <DataTable
        label="weeks"
        filter={false}
        columns={[
          { key: "week", label: "Week of" },
          { key: "opening", label: "Opens with", align: "right" },
          { key: "in", label: "Expected in", align: "right" },
          { key: "out", label: "Expected out", align: "right" },
          { key: "closing", label: "Leaves", align: "right" },
        ]}
        rows={weeks.map((w): DataRow => ({
          key: w.week,
          cells: {
            week: week(w.week),
            opening: money(w.opening),
            in: money(w.expected_in),
            out: money(w.expected_out),
            closing: money(w.closing),
          },
          sort: { week: w.week, closing: w.closing },
        }))}
        empty="No week to show."
      />

      <h2 className="h2" style={{ marginTop: 24 }}>
        Expected in
      </h2>
      <DataTable
        label="expectations"
        filter={false}
        columns={[
          { key: "month", label: "Month" },
          { key: "band", label: "How certain" },
          { key: "amount", label: "Amount", align: "right" },
          { key: "note", label: "Where it comes from" },
        ]}
        rows={bands(revenue as never)}
        empty="No open authorization and no item in the pipeline."
      />

      <h2 className="h2" style={{ marginTop: 24 }}>
        Expected out
      </h2>
      <DataTable
        label="expectations"
        filter={false}
        columns={[
          { key: "month", label: "Month" },
          { key: "band", label: "What" },
          { key: "amount", label: "Amount", align: "right" },
          { key: "note", label: "Where it comes from" },
        ]}
        rows={bands(cost as never)}
        empty="Nothing owed and no three months of history to average."
      />

      {me.role === "Admin" && (
        <ForecastSettings
          cashFloor={settings?.cash_floor ?? null}
          tolerance={settings?.budget_tolerance ?? 10}
        />
      )}
    </>
  );
}
