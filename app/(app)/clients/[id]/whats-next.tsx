import Link from "next/link";

/**
 * What this client needs, under their name.
 *
 * Worked out by the database (client_next_actions, 0109) so the strip cannot
 * disagree with anything else that asks the same question. Each item says
 * what it is, what makes it due, and opens where it is dealt with - one tap,
 * not a hunt through six tabs.
 *
 * Nothing due is worth saying out loud: a record with a clear strip is the
 * answer to "is there anything I should be doing for this person", and an
 * empty space is not an answer.
 */
export type NextAction = {
  kind: string;
  title: string;
  detail: string;
  href: string;
  urgency: number;
};

const WORD: Record<string, string> = {
  appointment: "Appointment",
  form: "Billing",
  authorization: "Authorization",
  text: "Text",
  consent: "Consent",
  retention: "Placement",
};

export function WhatsNext({ items }: { items: NextAction[] }) {
  if (items.length === 0) {
    return (
      <p className="next-clear no-print">
        Nothing is due for this client: no appointment booked, no form holding up billing, nothing unanswered.
      </p>
    );
  }

  return (
    <ul className="next-strip no-print" aria-label="What is next for this client">
      {items.map((item, i) => (
        <li key={`${item.kind}-${i}`} className={item.urgency <= 1 ? "soon" : undefined}>
          <Link href={item.href}>
            <span className="lock">{WORD[item.kind] ?? item.kind}</span>
            <b>{item.title}</b>
            {item.detail && <span className="next-detail">{item.detail}</span>}
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
  counselorName,
  billingOffice,
  canText,
  consentState,
  unbilled,
  clientId,
}: {
  stage: string;
  assignedName: string | null;
  counselorName: string | null;
  billingOffice: string | null;
  canText: boolean;
  consentState: string | null;
  unbilled: number;
  clientId: string;
}) {
  const money = (n: number) => `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  return (
    <p className="sub status-line" style={{ marginTop: 4 }}>
      <span className="chip gold">{stage}</span>{" "}
      <span>Assigned to {assignedName ?? "nobody"}</span>
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
    </p>
  );
}
