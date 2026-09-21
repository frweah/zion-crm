import Link from "next/link";
import type { Caseload } from "@/lib/caseload";
import { setCaseloadMine } from "./caseload-actions";

/** All · Mine, remembered for the person; the same choice on both screens. */
function MineToggle({ caseload }: { caseload: Caseload }) {
  return (
    <form action={setCaseloadMine} className="segmented caseload-toggle" role="group" aria-label="Whose caseload">
      <button type="submit" name="mine" value="false" className={!caseload.mine ? "on" : undefined} aria-pressed={!caseload.mine}>
        All
      </button>
      <button
        type="submit"
        name="mine"
        value="true"
        className={caseload.mine ? "on" : undefined}
        aria-pressed={caseload.mine}
        title={`Only clients ${caseload.mineLabel}`}
      >
        Mine
      </button>
    </form>
  );
}

/**
 * The caseload at a glance (lib/caseload.ts): three counts and a bar per
 * stage, each a link to the Clients list filtered to exactly what it counts.
 *
 * Two sizes: the full card on the dashboard, and a slim strip across the top
 * of the Clients list, so the numbers stay in sight while moving through it.
 */
export function CaseloadSummary({ caseload, slim = false }: { caseload: Caseload; slim?: boolean }) {
  const peak = Math.max(1, ...caseload.byStage.map((s) => s.count));
  const counts = (
    <div className="caseload-counts">
      <Link href={caseload.hrefs.total}>
        <b>{caseload.total}</b> clients
      </Link>
      <Link href={caseload.hrefs.active}>
        <b>{caseload.active}</b> active
      </Link>
      <Link href={caseload.hrefs.newThisMonth}>
        <b>{caseload.newThisMonth}</b> new this month
      </Link>
    </div>
  );

  if (slim) {
    return (
      <nav className="caseload-strip" aria-label={`${caseload.scopeLabel}, by stage`}>
        <MineToggle caseload={caseload} />
        <span className="lock">{caseload.scopeLabel}</span>
        {counts}
        <span className="caseload-stages">
          {caseload.byStage.map((s) => (
            <Link key={s.stage} href={s.href} title={`${s.count} active at ${s.stage}`}>
              {s.stage} <b>{s.count}</b>
            </Link>
          ))}
        </span>
      </nav>
    );
  }

  return (
    <section className="card day-section caseload" aria-labelledby="caseload-title">
      <h2 className="h2" id="caseload-title">
        Caseload <span className="day-total">{caseload.scopeLabel.toLowerCase()}</span>
        <MineToggle caseload={caseload} />
      </h2>
      {caseload.total === 0 ? (
        <p className="empty">
          {caseload.scope === "mine" ? "No clients are assigned to you yet." : "No clients to count yet."}
        </p>
      ) : (
        <>
          {counts}
          {caseload.active === 0 ? (
            <p className="empty">None of them is active.</p>
          ) : (
            <ul className="caseload-bars" aria-label="Active clients by stage">
              {caseload.byStage.map((s) => (
                <li key={s.stage}>
                  <Link href={s.href}>
                    <span className="caseload-stage">{s.stage}</span>
                    <span className="caseload-track" aria-hidden="true">
                      <span className="caseload-fill" style={{ width: `${(s.count / peak) * 100}%` }} />
                    </span>
                    <b className="caseload-n">{s.count}</b>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </section>
  );
}
