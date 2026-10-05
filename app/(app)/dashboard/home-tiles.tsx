import Link from "next/link";

/**
 * Home as a grid of tiles (Design language, §1).
 *
 * A tile is one number and one place to go. The dashboard was a column of
 * cards somebody scrolled through to find out whether anything had happened;
 * this is the same information in the shape the team already reads every day
 * in Connecteam - what is waiting, how much of it, and a tap to it.
 *
 * The feed below the tiles is what needs a person rather than a number: the
 * things that cannot be counted without being read.
 */
export type Tile = {
  key: string;
  label: string;
  value: string;
  note: string;
  href: string;
  /** Draws the eye: something is late or nobody has it. */
  bad?: boolean;
  /** The one tile that is an action rather than a count. */
  lead?: boolean;
};

export function HomeTiles({ tiles }: { tiles: Tile[] }) {
  return (
    <div className="tiles">
      {tiles.map((t) => (
        <Link key={t.key} href={t.href} className={"tile" + (t.lead ? " tile-lead" : "") + (t.bad ? " tile-bad" : "")}>
          <span className="tile-label">{t.label}</span>
          <span className="tile-value">{t.value}</span>
          <span className="tile-note">{t.note}</span>
        </Link>
      ))}
    </div>
  );
}
