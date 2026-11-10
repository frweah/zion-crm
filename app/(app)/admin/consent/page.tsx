import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";
import { RecordConsent } from "./record-consent";

/**
 * Texting consent, one number at a time (owner, 9 November 2026).
 *
 * "List every active client and contact number with consent not Yes so he can
 * record them one by one; no bulk flip."
 *
 * The no-bulk-flip is the whole design. Consent is a thing a person said, and
 * a button that marked thirty numbers as consented would be a record of
 * nothing — worse than no record, because it would look like evidence. So
 * every row is its own form with its own note saying how it was given, and
 * there is no action on this screen that touches more than one number.
 *
 * The practice has had consent per number all along: `sms_consent_events`
 * carries the number it was given for. What it did not have was anywhere to
 * put a second number, so a client with three had one on the record and the
 * other two nowhere. Both halves exist now, and this is the list that falls
 * out of them.
 */
export const dynamic = "force-dynamic";

type Row = {
  client_id: string;
  contact_id: string | null;
  phone: string;
  label: string;
  whose: string;
  whose_name: string;
  relationship: string;
  texts_here: boolean;
  state: string | null;
  since: string | null;
  method: string | null;
  note: string | null;
  can_text: boolean | null;
};

export default async function ConsentPage({
  searchParams,
}: {
  searchParams: Promise<{ show?: string }>;
}) {
  const me = await requireStaff();
  const { show } = await searchParams;
  const all = show === "all";

  if (me.role !== "Admin") {
    return (
      <>
        <PageHead title="Texting consent" context="Every number the practice holds, and what may be sent to it" />
        <div className="alert">
          This list is Admin&apos;s. Consent for one client&apos;s numbers is on their own record.
        </div>
      </>
    );
  }

  const supabase = await createClient();
  const [{ data: rows }, { data: clients }] = await Promise.all([
    supabase
      .from("sms_consent_numbers")
      .select(
        "client_id, contact_id, phone, label, whose, whose_name, relationship, texts_here, state, since, method, note, can_text",
      ),
    supabase.from("clients").select("id, name, status").neq("status", "Closed"),
  ]);

  const open = new Map((clients ?? []).map((c) => [c.id, c]));
  const numbers = ((rows ?? []) as Row[])
    // Active work only. A closed client's numbers are history, and a list that
    // asks Francis to ring people the practice is no longer working with is a
    // list he stops reading.
    .filter((n) => open.has(n.client_id))
    .filter((n) => all || !n.can_text)
    .sort((a, b) => {
      const an = open.get(a.client_id)?.name ?? "";
      const bn = open.get(b.client_id)?.name ?? "";
      return an.localeCompare(bn) || a.phone.localeCompare(b.phone);
    });

  const waiting = ((rows ?? []) as Row[]).filter((n) => open.has(n.client_id) && !n.can_text).length;

  return (
    <>
      <PageHead
        title="Texting consent"
        context="Every number the practice holds, and what may be sent to it"
      />

      <div className="segmented" role="group" aria-label="Which numbers" style={{ marginBottom: 12 }}>
        <Link href="/admin/consent" className={!all ? "on" : undefined}>
          Cannot be texted ({waiting})
        </Link>
        <Link href="/admin/consent?show=all" className={all ? "on" : undefined}>
          Every number
        </Link>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="numbers"
          sortBy
          pageSize={50}
          columns={[
            { key: "client", label: "Client" },
            { key: "whose", label: "Whose number" },
            { key: "number", label: "Number" },
            { key: "consent", label: "Consent" },
            { key: "recorded", label: "Recorded" },
            { key: "record", label: "" },
          ]}
          rows={numbers.map((n) => {
            const client = open.get(n.client_id);
            const name = client?.name ?? "";
            return {
              key: `${n.client_id}:${n.phone}`,
              text: [name, n.whose_name, n.phone, n.state ?? "not recorded"].join(" "),
              sort: {
                client: name,
                whose: n.whose_name,
                number: n.phone,
                consent: n.state ?? "",
                recorded: n.since ?? "",
              },
              cells: {
                client: (
                  <Link href={`/clients/${n.client_id}?tab=profile`} style={{ color: "var(--teal)" }}>
                    {name}
                  </Link>
                ),
                whose:
                  n.whose === "Contact" ? (
                    <>
                      {n.whose_name}
                      <span className="lock"> · {n.relationship}</span>
                    </>
                  ) : (
                    <span className="lock">the client</span>
                  ),
                number: (
                  <span style={{ whiteSpace: "nowrap" }}>
                    {n.phone}
                    <span className="lock"> · {n.label}</span>
                    {n.texts_here && <span className="chip" style={{ marginLeft: 6 }}>texts go here</span>}
                  </span>
                ),
                consent: n.can_text ? (
                  <span className="chip ok">Yes</span>
                ) : n.state ? (
                  <span className="chip bad">{n.state}</span>
                ) : (
                  <span className="chip warn">Not recorded</span>
                ),
                recorded: n.since ? (
                  <span style={{ whiteSpace: "nowrap" }}>
                    {String(n.since).slice(0, 10)}
                    {n.method ? <span className="lock"> · {n.method}</span> : null}
                  </span>
                ) : (
                  <span className="lock">—</span>
                ),
                record: <RecordConsent clientId={n.client_id} phone={n.phone} who={n.whose_name} />,
              },
            };
          })}
          empty={
            all
              ? "No numbers on file yet — they go on each client's record."
              : "Every number the practice holds may be texted."
          }
        />
      </div>

      <p className="lock" style={{ marginTop: 10 }}>
        One number at a time, with how it was given.
      </p>
    </>
  );
}
