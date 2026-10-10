import Link from "next/link";

/**
 * The way back, in one place.
 *
 * Every screen that was reached by clicking into it says how to get out, and
 * says it the same way: one line above the title, the arrow and the name of
 * what you came from. There is one of these rather than one per header,
 * because two definitions of the same affordance is how the record pages and
 * the hub tabs ended up with different answers in the first place.
 */
export function BackLink({ href, label }: { href: string; label: string }) {
  return (
    <p className="sub record-back no-print">
      <Link href={href}>← {label}</Link>
    </p>
  );
}
