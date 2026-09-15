import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp, today } from "@/lib/constants";
import { DataTable } from "../../data-table";

/**
 * Who read what.
 *
 * The screen exists for a question that will be asked from outside: a client,
 * or USOR, wanting to know who has looked at a file. Answering it should be
 * reading a list, not a database query written under pressure.
 *
 * Filterable by client and by person, because those are the two shapes the
 * question comes in — "who saw mine" and "what did they look at". The period
 * and the kind of record are a choice of filter, so they are .segmented rather
 * than a row of tabs inside a page that already has its own.
 */

const SUBJECTS = [
  "Client restricted details",
  "Client intake",
  "Contractor tax number",
  "Signed tax form",
];

type Row = {
  id: number;
  at: string;
  staff_id: string | null;
  staff_name: string;
  staff_role: string;
  subject: string;
  client_id: string | null;
  about_staff: string | null;
  purpose: string;
};

export default async function AccessLogPage({
  searchParams,
}: {
  searchParams: Promise<{ client?: string; who?: string; subject?: string; days?: string }>;
}) {
  const me = await requireStaff();
  if (me.role !== "Admin") redirect("/dashboard");

  const { client, who, subject, days: rawDays } = await searchParams;
  const days = /^[0-9]+$/.test(rawDays ?? "") ? Number(rawDays) : 30;

  const supabase = await createClient();

  let query = supabase
    .from("access_log")
    .select("id, at, staff_id, staff_name, staff_role, subject, client_id, about_staff, purpose")
    .order("at", { ascending: false })
    .limit(500);

  if (days > 0) query = query.gte("at", new Date(Date.now() - days * 86400000).toISOString());
  if (client) query = query.eq("client_id", client);
  if (who) query = query.eq("staff_id", who);
  if (subject) query = query.eq("subject", subject);

  const [{ data: rows }, { data: clients }, { data: staff }] = await Promise.all([
    query,
    supabase.from("clients").select("id, name").order("name"),
    supabase.from("staff").select("id, name").order("name"),
  ]);

  const entries = (rows ?? []) as Row[];
  const clientName = new Map((clients ?? []).map((c) => [c.id, c.name]));
  const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));

  const refusals = entries.filter((e) => e.purpose.endsWith("refused")).length;

  const link = (patch: Record<string, string>) => {
    const params = new URLSearchParams();
    if (client) params.set("client", client);
    if (who) params.set("who", who);
    if (subject) params.set("subject", subject);
    params.set("days", String(days));
    for (const [k, v] of Object.entries(patch)) {
      if (v) params.set(k, v);
      else params.delete(k);
    }
    return `/admin/system?${params.toString()}#access-log`;
  };

  return (
    <>
      <h2 className="h2">Access log</h2>
      <p className="sub">
        Every time somebody opened a client&apos;s restricted details or intake, a contractor&apos;s
        tax number, or a filed tax form
      </p>

      <div className="card" style={{ margin: "14px 0" }}>
        <div className="row2">
          <label className="field" style={{ maxWidth: 240, marginBottom: 0 }}>
            Client
            <form>
              <input type="hidden" name="days" value={days} />
              <select name="client" defaultValue={client ?? ""}>
                <option value="">Anyone&apos;s file</option>
                {(clients ?? []).map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
              <button className="btn ghost" type="submit" style={{ marginTop: 6, width: "100%" }}>
                Show
              </button>
            </form>
          </label>

          <label className="field" style={{ maxWidth: 220, marginBottom: 0 }}>
            Who looked
            <form>
              <input type="hidden" name="days" value={days} />
              {client && <input type="hidden" name="client" value={client} />}
              <select name="who" defaultValue={who ?? ""}>
                <option value="">Anybody</option>
                {(staff ?? []).map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
              <button className="btn ghost" type="submit" style={{ marginTop: 6, width: "100%" }}>
                Show
              </button>
            </form>
          </label>

          <div className="field" style={{ marginBottom: 0 }}>
            Since
            <div>
              <div className="segmented" style={{ marginTop: 6 }}>
                {[
                  { d: 7, label: "A week" },
                  { d: 30, label: "A month" },
                  { d: 365, label: "A year" },
                  { d: 0, label: "Everything" },
                ].map((o) => (
                  <Link
                    key={o.d}
                    href={link({ days: String(o.d) })}
                    className={days === o.d ? "on" : ""}
                  >
                    {o.label}
                  </Link>
                ))}
              </div>
            </div>
          </div>
        </div>

        <div className="segmented" style={{ marginTop: 12 }}>
          <Link href={link({ subject: "" })} className={!subject ? "on" : ""}>
            Everything
          </Link>
          {SUBJECTS.map((s) => (
            <Link key={s} href={link({ subject: s })} className={subject === s ? "on" : ""}>
              {s}
            </Link>
          ))}
        </div>
      </div>

      {refusals > 0 && (
        <div className="alert" style={{ marginBottom: 14 }}>
          <b>
            {refusals} of these are refusals — somebody opened a file they are not allowed to see.
          </b>{" "}
          That is usually a client assigned to somebody else, and usually innocent. It is here
          because the times it is not are the times it matters.
        </div>
      )}

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="entries"
          columns={[
            { key: "when", label: "When" },
            { key: "who", label: "Who" },
            { key: "what", label: "What" },
            { key: "whose", label: "Whose" },
            { key: "why", label: "Why" },
          ]}
          rows={entries.map((e) => {
            const refused = e.purpose.endsWith("refused");
            const whose = e.client_id
              ? (clientName.get(e.client_id) ?? "a client since removed")
              : e.about_staff
                ? (staffName.get(e.about_staff) ?? "a staff member since removed")
                : "";
            return {
              key: String(e.id),
              text: `${e.staff_name} ${e.staff_role} ${e.subject} ${whose} ${e.purpose}`,
              sort: { when: e.at, who: e.staff_name, what: e.subject, whose, why: e.purpose },
              cells: {
                when: <span style={{ whiteSpace: "nowrap" }}>{fmtStamp(e.at)}</span>,
                who: (
                  <>
                    {e.staff_name}
                    <div className="lock">{e.staff_role}</div>
                  </>
                ),
                what: e.subject,
                whose: e.client_id ? (
                  <Link href={`/clients/${e.client_id}`}>{whose}</Link>
                ) : e.about_staff ? (
                  whose
                ) : (
                  <span className="lock">—</span>
                ),
                why: refused ? (
                  <>
                    <span className="chip bad">Refused</span>{" "}
                    <span style={{ color: "var(--bad)" }}>{e.purpose}</span>
                  </>
                ) : (
                  e.purpose || <span className="lock">—</span>
                ),
              },
            };
          })}
          empty="Nothing was recorded in this period."
        />
      </div>

      <p className="lock" style={{ marginTop: 10 }}>
        Append-only: nothing here can be edited or deleted, including by you. Entries are written
        by the database as part of handing the data over, so there is no way to read a restricted
        field without one. Read on {today()}, showing at most 500 entries.
      </p>

      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>What this does not cover</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          Worth knowing before anybody quotes it as complete.
        </p>
        <ul style={{ margin: 0, paddingLeft: 20, fontSize: 13, lineHeight: 1.6 }}>
          <li>
            Reads made with the database password or the service key — a backup, a migration, a
            developer with the connection string. Those are two secrets in two places, not a log.
          </li>
          <li>
            What somebody did with the data once they had it. A screenshot, a note taken by hand,
            a form printed and carried out of the building.
          </li>
          <li>
            The rest of the record. A client&apos;s name, stage, notes and hours are visible to
            every active staff member by design, and logging every read of those would be a
            haystack rather than a record.
          </li>
        </ul>
      </div>
    </>
  );
}
