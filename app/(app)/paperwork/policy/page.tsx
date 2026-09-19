import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { PolicySignForm } from "../onboarding/steps";

/**
 * A staff policy, signed again.
 *
 * When a policy gets a new version, everybody signs it on their next sign-in:
 * every other screen sends them here until they have (the layout, 0103). What
 * they signed before stays on file against the version it was - a signature
 * in the app, or the paper form ticked on their checklist, which was
 * version 1.
 */
export default async function PolicyPage() {
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data: policy }, { data: signatures }, { data: personal }, { data: paper }] = await Promise.all([
    supabase.from("staff_policies").select("key, version, title, body").eq("key", "data-handling").eq("is_current", true).maybeSingle(),
    supabase
      .from("staff_policy_signatures")
      .select("policy_version, signer_name, signed_at")
      .eq("staff_id", me.id)
      .eq("policy_key", "data-handling")
      .order("policy_version"),
    supabase.from("staff_personal").select("legal_name").eq("staff_id", me.id).maybeSingle(),
    supabase.from("staff_checklist").select("done_on").eq("staff_id", me.id).eq("auto_key", "policy_signed").maybeSingle(),
  ]);

  if (!policy) {
    return (
      <>
        <PageHead title="Data-handling policy" context="Nothing to sign." />
        <p className="empty">No policy is in force.</p>
      </>
    );
  }

  const signedNow = (signatures ?? []).find((s) => s.policy_version === policy.version);
  const earlier = (signatures ?? []).filter((s) => s.policy_version !== policy.version);
  const blocks = policy.body as unknown as { type: string; text: string }[];

  return (
    <>
      <PageHead
        title={`${policy.title}, version ${policy.version}`}
        context={
          signedNow
            ? `You signed this version on ${fmtStamp(signedNow.signed_at)}.`
            : "The policy has changed since you last signed it. Read it and sign this version to carry on."
        }
      />

      {(earlier.length > 0 || paper?.done_on) && (
        <div className="card" style={{ marginBottom: 14 }}>
          <h3>On file</h3>
          {paper?.done_on && (
            <p style={{ margin: "0 0 4px" }}>Version 1, signed on paper - recorded {paper.done_on}.</p>
          )}
          {earlier.map((s) => (
            <p key={s.policy_version} style={{ margin: "0 0 4px" }}>
              Version {s.policy_version}, signed by {s.signer_name} on {fmtStamp(s.signed_at)}.
            </p>
          ))}
          <p className="lock" style={{ margin: "6px 0 0" }}>
            These stay on your file. Signing the new version adds to them; it does not replace them.
          </p>
        </div>
      )}

      <section className="card" style={{ marginBottom: 14 }}>
        <div style={{ maxWidth: "70ch" }}>
          {blocks.map((b, i) =>
            b.type === "h2" ? (
              <h4 key={i} style={{ margin: "16px 0 6px" }}>
                {b.text}
              </h4>
            ) : b.type === "li" ? (
              <p key={i} style={{ margin: "0 0 8px", paddingLeft: 14, borderLeft: "2px solid var(--line)" }}>
                {b.text}
              </p>
            ) : (
              <p key={i} style={{ margin: "0 0 10px" }}>
                {b.text}
              </p>
            ),
          )}
        </div>
        {signedNow ? (
          <div className="alert ok" style={{ marginTop: 12 }}>
            Signed. The signed copy is on your file.{" "}
            <Link href="/dashboard" style={{ color: "inherit" }}>
              <b>Go to the dashboard</b>
            </Link>
          </div>
        ) : (
          <PolicySignForm version={policy.version} legalName={personal?.legal_name || me.name} />
        )}
      </section>
    </>
  );
}
