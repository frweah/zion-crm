import Link from "next/link";
import type { ReactNode } from "react";

/**
 * A figure on Insights: the label above in small tracked capitals at full
 * --muted, the number in the serif at 32px, and - where the figure is a count
 * or a sum that happens month by month - the last twelve months drawn under it.
 *
 * No border: the figures sit on the page as a row of numbers, not a row of
 * boxes. A sparkline appears only where a real monthly series exists; a
 * balance as of today (what is owed, what is committed) has no history kept,
 * and drawing one would be inventing it.
 */
export type MonthPoint = { month: string; value: number };

const TONE: Record<string, string> = {
  bad: "var(--bad)",
  good: "var(--accent-text)",
  warn: "var(--warn-ink)",
};

/** Twelve months back from the month given (YYYY-MM), oldest first. */
export function lastTwelveMonths(month: string): string[] {
  const [y, m] = month.split("-").map(Number);
  const out: string[] = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date(Date.UTC(y, m - 1 - i, 1));
    out.push(d.toISOString().slice(0, 7));
  }
  return out;
}

const MONTH = new Intl.DateTimeFormat("en-US", { month: "short", year: "numeric", timeZone: "UTC" });
const monthName = (m: string) => MONTH.format(new Date(`${m}-01T00:00:00Z`));

/** Twelve months as a line with its area, the latest month marked. */
function Sparkline({ series, describe }: { series: MonthPoint[]; describe: (v: number) => string }) {
  const W = 132;
  const H = 30;
  const PAD = 3;
  const max = Math.max(...series.map((p) => p.value), 0);
  const x = (i: number) => PAD + (i * (W - PAD * 2)) / Math.max(series.length - 1, 1);
  const y = (v: number) => (max === 0 ? H - PAD : H - PAD - (v / max) * (H - PAD * 2));
  const line = series.map((p, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)} ${y(p.value).toFixed(1)}`).join(" ");
  const area = `${line} L${x(series.length - 1).toFixed(1)} ${H - PAD} L${x(0).toFixed(1)} ${H - PAD} Z`;
  const last = series[series.length - 1];
  const label =
    `Last 12 months: ` + series.map((p) => `${monthName(p.month)} ${describe(p.value)}`).join(", ") + ".";

  return (
    <svg className="spark" viewBox={`0 0 ${W} ${H}`} width={W} height={H} role="img" aria-label={label}>
      <title>{label}</title>
      <line x1={PAD} x2={W - PAD} y1={H - PAD} y2={H - PAD} className="spark-base" />
      <path d={area} className="spark-area" />
      <path d={line} className="spark-line" />
      <circle cx={x(series.length - 1)} cy={y(last.value)} r="2.5" className="spark-end" />
    </svg>
  );
}

export function Kpi({
  value,
  label,
  tone,
  detail,
  href,
  series,
  describe = (v) => String(v),
}: {
  value: ReactNode;
  label: ReactNode;
  tone?: "bad" | "good" | "warn";
  detail?: ReactNode;
  /** A figure whose home is another screen links there. */
  href?: string;
  /** The last twelve months, oldest first, when this figure has a monthly series. */
  series?: MonthPoint[];
  /** How one month's value reads aloud: "$1,200", "3 referrals". */
  describe?: (v: number) => string;
}) {
  const body = (
    <>
      <div className="kpi-label">{label}</div>
      <div className="kpi-figure" style={tone ? { color: TONE[tone] } : undefined}>
        {value}
      </div>
      {series && series.length > 1 && <Sparkline series={series} describe={describe} />}
      {detail && <p className="lock kpi-detail">{detail}</p>}
    </>
  );
  return href ? (
    <Link href={href} className="kpi kpi-link">
      {body}
    </Link>
  ) : (
    <div className="kpi">{body}</div>
  );
}
