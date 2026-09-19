import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { myMailAccess } from "@/lib/mail-access";
import { clientTag } from "@/lib/graph";
import { PageHead } from "../../page-head";
import { ComposeForm } from "../mail-forms";

/**
 * A new message (Messaging brief, M). Opened blank from Mail, or from a record:
 * "Email the counselor" puts the counselor in To, the billing office in Cc and
 * the client in the subject - their name and number, the same tag the sync
 * recognises, and nothing restricted. Sent from the person's own mailbox, only
 * when they press Send.
 */
async function billingEmailFor(
  supabase: Awaited<ReturnType<typeof createClient>>,
  billingOfficeId: string | null | undefined,
): Promise<string> {
  if (!billingOfficeId) return "";
  const { data } = await supabase.from("billing_offices").select("billing_email").eq("id", billingOfficeId).maybeSingle();
  return data?.billing_email ?? "";
}

export default async function ComposePage({
  searchParams,
}: {
  searchParams: Promise<{ to?: string; cc?: string; subject?: string; client?: string; counselor?: string }>;
}) {
  const params = await searchParams;
  const access = await myMailAccess();
  const supabase = await createClient();

  let to = params.to ?? "";
  let cc = params.cc ?? "";
  let subject = params.subject ?? "";
  let about = "";

  if (params.client) {
    const [{ data: client }, { data: office }] = await Promise.all([
      supabase
        .from("clients")
        .select("name, client_no, counselor:counselors!clients_counselor_id_fkey(name, email)")
        .eq("id", params.client)
        .maybeSingle() as unknown as Promise<{
        data: { name: string; client_no: number | null; counselor: { name: string; email: string | null } | null } | null;
      }>,
      supabase.from("client_billing_office").select("billing_office_id").eq("client_id", params.client).maybeSingle(),
    ]);
    if (client) {
      to = to || (client.counselor?.email ?? "");
      cc = cc || (await billingEmailFor(supabase, office?.billing_office_id));
      subject = subject || `${client.name}${client.client_no ? ` ${clientTag(Number(client.client_no))}` : ""}`;
      about = `About ${client.name}${client.counselor ? `, to their counselor ${client.counselor.name}` : ""}.`;
    }
  } else if (params.counselor) {
    const { data: counselor } = await supabase
      .from("counselors")
      .select("name, email, office")
      .eq("id", params.counselor)
      .maybeSingle();
    if (counselor) {
      to = to || (counselor.email ?? "");
      if (!cc && counselor.office) {
        const { data: office } = await supabase.from("offices").select("billing_office_id").eq("name", counselor.office).maybeSingle();
        cc = await billingEmailFor(supabase, office?.billing_office_id);
      }
      about = `To ${counselor.name}.`;
    }
  }

  return (
    <>
      <PageHead
        title="New message"
        context={about || "From your own Outlook, when you press Send"}
        actions={
          <Link className="btn ghost" href="/mail" style={{ textDecoration: "none" }}>
            Back to Mail
          </Link>
        }
      />
      {!access.ok ? (
        <div className="card">
          <p style={{ margin: 0 }}>{access.message}</p>
        </div>
      ) : (
        <>
          {!access.canSend && (
            <div className="alert" style={{ marginBottom: 12 }}>
              Sending is not turned on for your Outlook yet.{" "}
              <a href="/api/auth/microsoft/start?send=1" style={{ color: "inherit" }}>
                <b>Turn sending on</b>
              </a>{" "}
              - one reconnect - and this message can go.
            </div>
          )}
          <ComposeForm to={to} cc={cc} subject={subject} from={access.email} canSend={access.canSend} />
        </>
      )}
    </>
  );
}
