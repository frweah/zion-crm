import { createClient } from "@/lib/supabase/server";
import { fmtAgo, fmtStamp } from "@/lib/constants";
import { DataTable, type DataRow } from "../../data-table";

/**
 * Who is watching each mailbox, and until when (owner, 24 Oct 2026).
 *
 * Microsoft's change notifications are what make a client's mail arrive in a
 * minute rather than at the next sweep, and a delegated subscription to them
 * dies of old age inside about seventy hours. Nothing renews one but the
 * fifteen-minute sweep, so the failure this screen exists to show is a quiet
 * one: everything looks fine, and three days later no mail arrives.
 *
 * The expiry is the number to read. The sweep renews at two days out, so a
 * date less than a day away means renewal has been failing for a day -
 * `supabase/verify_mail_subscriptions.sql` fails on the same condition, and
 * this is where somebody looks after it does.
 */
type Row = {
  staff_id: string;
  mailbox_address: string;
  subscription_id: string;
  expires_at: string | null;
  renewed_at: string | null;
  last_notified_at: string | null;
  notifications: number | null;
  last_error: string | null;
};

const DAY = 24 * 3600 * 1000;

export default async function MailboxWatchSection() {
  const supabase = await createClient();
  const [{ data: subs }, { data: staff }, { data: state }] = await Promise.all([
    supabase
      .from("microsoft_subscriptions")
      .select("staff_id, mailbox_address, subscription_id, expires_at, renewed_at, last_notified_at, notifications, last_error"),
    supabase.from("staff").select("id, name"),
    supabase.from("microsoft_sync_state").select("staff_id, last_run_at, last_error"),
  ]);

  const name = new Map((staff ?? []).map((s) => [s.id, s.name]));
  const swept = new Map((state ?? []).map((s) => [s.staff_id, s]));
  const rows = ((subs ?? []) as Row[]).sort((a, b) =>
    (name.get(a.staff_id) ?? "").localeCompare(name.get(b.staff_id) ?? ""),
  );

  const table: DataRow[] = rows.map((r) => {
    const left = r.expires_at ? new Date(r.expires_at).getTime() - Date.now() : -1;
    const dying = left < DAY;
    const sweep = swept.get(r.staff_id);
    return {
      key: r.staff_id + r.mailbox_address,
      text: `${name.get(r.staff_id) ?? ""} ${r.mailbox_address}`,
      sort: {
        who: name.get(r.staff_id) ?? "",
        expires: r.expires_at ?? "",
        renewed: r.renewed_at ?? "",
        swept: sweep?.last_run_at ?? "",
      },
      cells: {
        who: (
          <>
            <b>{name.get(r.staff_id) ?? "—"}</b>
            {r.mailbox_address && <span className="lock"> · {r.mailbox_address}</span>}
          </>
        ),
        expires: r.expires_at ? (
          <>
            {fmtStamp(r.expires_at)}
            {dying && <span className="chip bad"> Renew</span>}
          </>
        ) : (
          <span className="chip bad">Not subscribed</span>
        ),
        renewed: <span className="lock">{r.renewed_at ? fmtAgo(r.renewed_at) : "never"}</span>,
        swept: <span className="lock">{sweep?.last_run_at ? fmtAgo(sweep.last_run_at) : "never"}</span>,
        posts: <span className="lock">{r.notifications ?? 0}</span>,
        trouble: r.last_error || sweep?.last_error ? (
          <span className="chip bad">{(r.last_error || sweep?.last_error || "").slice(0, 60)}</span>
        ) : null,
      },
    };
  });

  return (
    <>
      <h2 className="h2">Mailbox watch</h2>
      <p className="sub" style={{ margin: "4px 0 10px" }}>
        Microsoft stops telling us about a mailbox when its date passes
      </p>
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="watched mailboxes"
          columns={[
            { key: "who", label: "Mailbox" },
            { key: "expires", label: "Watched until" },
            { key: "renewed", label: "Renewed" },
            { key: "swept", label: "Swept" },
            { key: "posts", label: "Told us", sortable: false },
            { key: "trouble", label: "", sortable: false },
          ]}
          rows={table}
          empty="No mailbox is subscribed — connect Outlook and the sweep subscribes it."
        />
      </div>
    </>
  );
}
