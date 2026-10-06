import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ROLE_LABEL, type Role } from "@/lib/roles";
import { PageHead } from "../page-head";

/**
 * The directory (Design language, §3).
 *
 * Everybody the practice works with - colleagues and the counselors who refer
 * to it - with the two things anybody actually wants from a directory: the
 * number, and a way to start a conversation without first finding the person's
 * record.
 *
 * No photographs yet: the practice holds none, and a page of grey circles
 * where faces should be says less than initials do. The initials are the same
 * ones the avatar menu draws, so a person looks the same wherever they appear.
 */
function initials(name: string): string {
  const parts = name.trim().split(/\s+/);
  return ((parts[0]?.[0] ?? "") + (parts.length > 1 ? (parts[parts.length - 1][0] ?? "") : "")).toUpperCase() || "?";
}

export default async function DirectoryPage() {
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data: staff }, { data: counselors }] = await Promise.all([
    supabase
      .from("staff")
      .select("id, name, role, email, phone")
      .eq("active", true)
      .eq("is_system", false)
      .order("name"),
    supabase.from("counselors").select("id, name, agency, office, email, phone").order("name"),
  ]);

  return (
    <>
      <PageHead title="Directory" context="Colleagues, and the counselors who refer to the practice" />

      <section className="page-section">
        <h2 className="h2">Colleagues</h2>
        <div className="people">
          {(staff ?? []).map((s) => (
            <div key={s.id} className="person">
              <span className="person-face" aria-hidden="true">
                {initials(s.name)}
              </span>
              <span className="person-who">
                <b>{s.name}</b>
                <span className="lock">{ROLE_LABEL[s.role as Role] ?? s.role}</span>
              </span>
              <span className="person-do">
                {s.id !== me.id && <Link className="row-link" href={`/messages?to=${s.id}`}>Message</Link>}
                {s.phone && (
                  <a className="row-link" href={`tel:${s.phone.replace(/[^0-9+]/g, "")}`}>
                    {s.phone}
                  </a>
                )}
                {s.email && (
                  <a className="row-link" href={`mailto:${s.email}`}>
                    {s.email}
                  </a>
                )}
              </span>
            </div>
          ))}
        </div>
      </section>

      <section className="page-section">
        <h2 className="h2">Counselors</h2>
        <p className="lock" style={{ margin: "0 0 10px" }}>
          Their offices, contact log and hours requests are on{" "}
          <Link href="/counselors">Counselors</Link>.
        </p>
        <div className="people">
          {(counselors ?? []).map((c) => (
            <div key={c.id} className="person">
              <span className="person-face" aria-hidden="true">
                {initials(c.name)}
              </span>
              <span className="person-who">
                <b>
                  <Link href={`/counselors/${c.id}`}>{c.name}</Link>
                </b>
                <span className="lock">{[c.office, c.agency].filter(Boolean).join(" · ") || "Counselor"}</span>
              </span>
              <span className="person-do">
                {c.phone && (
                  <a className="row-link" href={`tel:${c.phone.replace(/[^0-9+]/g, "")}`}>
                    {c.phone}
                  </a>
                )}
                {c.email && (
                  <a className="row-link" href={`mailto:${c.email}`}>
                    {c.email}
                  </a>
                )}
              </span>
            </div>
          ))}
        </div>
      </section>
    </>
  );
}
