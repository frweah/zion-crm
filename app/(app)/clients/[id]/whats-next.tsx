import Link from "next/link";
import { kindWord, worstFirst, type NextStep } from "@/lib/next-steps";

/**
 * What this client needs, under their name.
 *
 * Worked out by `next_steps` (0405), which is the one answer every screen
 * reads - the board's cell, this strip, the rail counts, Home and the nightly
 * alerts. Before it the strip had its own nine rules and the board had four
 * others, and on 27 November 2026 four records said "Nothing is due" about a
 * client with an overdue task the board was naming in the next column.
 *
 * Each item says what it is, what makes it due, and opens where it is dealt
 * with - one tap, not a hunt through six tabs.
 *
 * Nothing due is worth saying out loud: a record with a clear strip is the
 * answer to "is there anything I should be doing for this person", and an
 * empty space is not an answer.
 */
export function WhatsNext({ items }: { items: NextStep[] }) {
  if (items.length === 0) {
    return (
      <p className="next-clear no-print">
        Nothing is due for this client: nothing unanswered, no task open, no form holding up billing.
      </p>
    );
  }

  return (
    <ul className="next-strip no-print" aria-label="What is next for this client">
      {worstFirst(items).map((item, i) => (
        <li key={`${item.kind}-${i}`} className={item.severity <= 1 ? "soon" : undefined}>
          <Link href={item.action_href}>
            <span className="lock">{kindWord(item.kind)}</span>
            <b>{item.what}</b>
            {item.who && <span className="next-detail">{item.who}</span>}
          </Link>
        </li>
      ))}
    </ul>
  );
}

/**
 * Where this client stands, in one line: who has them, who funds them, and
 * the two facts that decide what can be done today - whether they may be
 * texted, and what has been earned and not yet billed.
 */
export function StatusLine({
  stage,
  assignedName,
  billingName,
  counselorName,
  billingOffice,
  canText,
  consentState,
  unbilled,
  clientId,
}: {
  stage: string;
  assignedName: string | null;
  billingName: string | null;
  counselorName: string | null;
  billingOffice: string | null;
  canText: boolean;
  consentState: string | null;
  unbilled: number;
  clientId: string;
}) {
  const money = (n: number) => `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  return (
    <span className="status-line">
      <span className="chip gold">{stage}</span>{" "}
      <span>Job search {assignedName ?? "nobody"}</span>
      {" · "}
      <span>Billing {billingName ?? "nobody"}</span>
      {" · "}
      <span>Counselor {counselorName || "not set"}</span>
      {billingOffice && (
        <>
          {" · "}
          <span>Bills to {billingOffice}</span>
        </>
      )}
      {" · "}
      {canText ? (
        <Link href={`/clients/${clientId}?tab=messages`} className="chip ok" style={{ textDecoration: "none" }}>
          Can be texted
        </Link>
      ) : (
        <Link href={`/clients/${clientId}?tab=profile#texting`} className="chip bad" style={{ textDecoration: "none" }}>
          {consentState === "Withdrawn" ? "Replied STOP" : "No texting consent"}
        </Link>
      )}
      {unbilled > 0 && (
        <>
          {" · "}
          <Link href={`/clients/${clientId}?tab=billing`} className="chip warn" style={{ textDecoration: "none" }}>
            {money(unbilled)} unbilled
          </Link>
        </>
      )}
    </span>
  );
}
