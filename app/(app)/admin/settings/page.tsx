import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ORG } from "@/lib/roles";
import { EmployerDetails } from "./employer-details";

/**
 * Settings.
 *
 * What the practice is, as opposed to what it does. Only two kinds of thing
 * belong here: what the owner maintains, and what everything else reads.
 *
 * The employer block used to sit at the bottom of Paperwork, which is the
 * screen where each person signs their own tax form. An Admin-only field
 * about the company on a screen about yourself is the sort of thing that is
 * obvious to whoever put it there and to nobody else.
 */
export default async function SettingsPage() {
  const me = await requireStaff();
  if (me.role !== "Admin") redirect("/dashboard");

  const supabase = await createClient();
  const { data } = await supabase.rpc("get_employer_details");

  // One row, and the EIN is reduced to a yes/no here so the number itself
  // never reaches the browser.
  const employer = (data as unknown as
    | { legal_name: string; address: string; ein: string }[]
    | null)?.[0];

  return (
    <>
      <h1 className="h1">Settings</h1>
      <p className="sub">What the practice is, and what its paperwork says</p>

      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>The two names, and which goes where</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          These are deliberately different and are not to be reconciled.
        </p>
        <table className="t">
          <tbody>
            <tr>
              <td style={{ width: 200 }}>
                <b>{ORG.name}</b>
                <div className="lock">the dba</div>
              </td>
              <td>
                Everything a client or USOR sees: forms, progress reports, invoices, email, the
                outcomes one-pager. Set in the code, because it is not something that changes.
              </td>
            </tr>
            <tr>
              <td>
                <b>{employer?.legal_name || "— not set —"}</b>
                <div className="lock">the legal entity</div>
              </td>
              <td>
                Tax filings only: the employer block on a W-4, the payer on a 1099. Maintained
                below, because it is the owner&apos;s to change.
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      {employer && (
        // The legal name is not prefilled. It is not the trading name, and
        // offering the one as the other is how the wrong name gets onto a W-4.
        // The address is safe to suggest.
        <EmployerDetails
          legalName={employer.legal_name}
          address={employer.address || ORG.address}
          hasEin={Boolean(employer.ein)}
        />
      )}

      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>Kept elsewhere, on purpose</h3>
        <table className="t">
          <tbody>
            <tr>
              <td style={{ width: 200 }}>Tax years and 1099 thresholds</td>
              <td>
                <Link href="/admin/contractors">Contractors</Link> — they sit
                with the run they govern, and no run can be built on an unconfirmed threshold.
              </td>
            </tr>
            <tr>
              <td>Pay rates</td>
              <td>
                <Link href="/admin/staff">Staff</Link> — dated records against a person, so work
                keeps the rate it was done under.
              </td>
            </tr>
            <tr>
              <td>Texting consent</td>
              <td>
                Each client&apos;s own record. Consent is given by a person for a number, so
                there is nothing here to set for everybody.
              </td>
            </tr>
            <tr>
              <td>Rate schedule</td>
              <td>
                <Link href="/billing?tab=rates">Billing → Rate schedule</Link> — keyed by funding
                source, so a second funder needs no code change.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </>
  );
}
