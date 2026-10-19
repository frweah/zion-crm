import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PageHead } from "../../page-head";
import { Enrol } from "./enrol";

/**
 * A person's own second factor (0217).
 *
 * Reached from the avatar menu by anybody who wants one, and arrived at by
 * anybody who needs one — the layout sends them here when the practice
 * requires one and they have not got one, or when they have one and this
 * session has not used it yet.
 *
 * The assurance level is read here as well as in the layout, and it is the
 * whole reason this screen can tell the difference between somebody who still
 * owes us a code and somebody who is already through. Without it the screen
 * asked for a code, took it, succeeded, and asked again — which is what a
 * working enrolment looked like from the outside on 19 Oct.
 */
export default async function TwoFactorPage() {
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data }, { data: claims }] = await Promise.all([
    supabase.rpc("two_factor_state"),
    supabase.auth.getClaims(),
  ]);
  const state = Array.isArray(data) ? data[0] : null;
  const required = Boolean(state?.required);
  const enrolled = Boolean(state?.enrolled);
  const stepped = (claims?.claims as { aal?: string } | undefined)?.aal === "aal2";

  return (
    <>
      <PageHead
        title="Two-step sign-in"
        context={
          enrolled
            ? "Your password and a code from your phone"
            : "Your password, and a code from your phone"
        }
      />

      <Enrol hasFactor={enrolled} required={required} stepped={stepped} />

      <div className="card" style={{ marginTop: 14 }}>
        <p className="sub">
          {enrolled
            ? `Set up on this account, ${me.name}. If you lose the phone, the administrator can take it off so you can set it up again.`
            : "If you lose the phone afterwards, the administrator can take it off so you can set it up again."}
        </p>
      </div>
    </>
  );
}
