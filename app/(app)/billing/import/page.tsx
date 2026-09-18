import { can } from "@/lib/roles";
import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";

import { ImportForm } from "./import-form";
import { PageHead } from "../../page-head";

/**
 * Reading an authorization off the PDF USOR sends.
 *
 * The typing this replaces is the kind that goes wrong quietly: a rate keyed
 * as 4.50 instead of 45.00 is not noticed until an invoice is short, and an
 * authorization number with a digit missing is not noticed until USOR asks.
 */
export default async function ImportAuthorizationPage() {
  const me = await requireStaff();
  if (!can(me, "billing", "edit")) redirect("/billing");

  const supabase = await createClient();
  const { data: clients } = await supabase
    .from("clients")
    .select("id, name, agency_id")
    .neq("status", "Closed")
    .order("name");

  return (
    <>
      <p className="sub" style={{ marginBottom: 8 }}>
        <Link href="/billing?tab=authorizations" style={{ color: "var(--teal)" }}>
          ← Billing
        </Link>
      </p>

      <PageHead
        title="Read an authorization"
        context="Upload the PDF USOR sent, check what it says, and create the authorization from it"
      />

      <ImportForm clients={clients ?? []} />

      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>How this reads a file</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          Rules, not judgement. The PDF is opened here, its text is read, and each field is found
          by a labelled pattern — &ldquo;Total Hours&rdquo; followed by a number, &ldquo;Rate&rdquo;
          followed by an amount. Nothing is sent to any outside service, no model sees a client&apos;s
          authorization, and the same file gives the same answer every time.
        </p>
        <p className="sub">
          That also sets the limits. A label the rules do not know is left blank rather than
          guessed at, and a scanned or photographed authorization has no text to read at all —
          those still have to be typed in. Reading a scan needs optical character recognition,
          which is a later decision and is not built.
        </p>
        <p className="lock" style={{ margin: 0 }}>
          The rules live in one file with names on them, so a field that comes out wrong on a real
          USOR form is a rule to fix rather than a mystery.
        </p>
      </div>
    </>
  );
}
