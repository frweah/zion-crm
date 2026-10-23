import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { myMailAccess } from "@/lib/mail-access";
import { documentsForClient, recipientsForClient } from "@/lib/mail-filing";
import { RecordHeader } from "../../record-header";
import { ComposeForm } from "../mail-forms";
import { ClientComposeForm, type FilledTemplate } from "../client-compose";

/**
 * A new message (Messaging brief, M). Opened blank from Mail, from a
 * counselor's record, or about a client.
 *
 * About a client it is a different screen rather than the same one with the
 * boxes filled in (owner, 23 Oct 2026): the recipients are picked from the
 * record, the templates come with the facts already in them, documents are
 * attached from the client's file, and what goes is filed on the client and
 * written to the contact log. Sent from the person's own mailbox, only when
 * they press Send.
 */
async function billingEmailFor(
  supabase: Awaited<ReturnType<typeof createClient>>,
  billingOfficeId: string | null | undefined,
): Promise<string> {
  if (!billingOfficeId) return "";
  const { data } = await supabase.from("billing_offices").select("billing_email").eq("id", billingOfficeId).maybeSingle();
  return data?.billing_email ?? "";
}

/**
 * The three letters, filled in for this client, ready to choose between.
 *
 * One question for all of them (0240), not one per template: three round
 * trips is what the fourth template turns into four.
 */
async function templatesFor(
  supabase: Awaited<ReturnType<typeof createClient>>,
  clientId: string,
): Promise<FilledTemplate[]> {
  const { data } = await supabase.rpc("mail_templates_for", { p_client: clientId });
  return (data as unknown as FilledTemplate[] | null) ?? [];
}

export default async function ComposePage({
  searchParams,
}: {
  searchParams: Promise<{ to?: string; cc?: string; subject?: string; client?: string; counselor?: string }>;
}) {
  const params = await searchParams;
  const access = await myMailAccess();
  const supabase = await createClient();

  // ── About a client ──────────────────────────────────────────
  if (params.client) {
    const [{ recipients, clientName }, documents, templates] = await Promise.all([
      recipientsForClient(params.client),
      documentsForClient(params.client),
      templatesFor(supabase, params.client),
    ]);

    return (
      <>
        <RecordHeader
          back={{ href: "/mail", label: "Mail" }}
          title="New message"
          standing={clientName ? `About ${clientName}, filed on their record when it goes` : "About a client"}
          actions={
            <Link className="btn ghost" href={`/clients/${params.client}`} style={{ textDecoration: "none" }}>
              Back to the record
            </Link>
          }
        />
        {/*
          The screen is drawn whether or not Outlook is connected, and only
          Send is withheld.

          It used to be one or the other: no connection, no screen, just the
          message about connecting. But the recipients and the three letters
          are the practice's own facts and have nothing to do with Microsoft -
          somebody whose Outlook has quietly expired could not even see what
          the message would say, which is the wrong half to take away. It also
          meant nothing about this screen could be exercised on a deploy,
          because a throwaway account has no mailbox and never will.
        */}
        {!access.ok && (
          <div className="alert" style={{ marginBottom: 12 }}>
            {access.message}{" "}
            {access.reason !== "not-signed-in" && (
              <Link href="/dashboard#outlook" style={{ color: "inherit" }}>
                <b>Connect Outlook</b>
              </Link>
            )}
          </div>
        )}
        {access.ok && !access.canSend && (
          <div className="alert" style={{ marginBottom: 12 }}>
            Sending is not turned on for your Outlook yet.{" "}
            <a href="/api/auth/microsoft/start?send=1" style={{ color: "inherit" }}>
              <b>Turn sending on</b>
            </a>{" "}
            - one reconnect - and this message can go.
          </div>
        )}
        <ClientComposeForm
          clientId={params.client}
          clientName={clientName}
          recipients={recipients}
          documents={documents}
          templates={templates}
          from={access.ok ? access.email : (access.me?.email ?? "your own mailbox")}
          canSend={access.ok && access.canSend}
          defaultTo={recipients.filter((r) => r.kind === "counselor").map((r) => r.address.toLowerCase())}
        />
      </>
    );
  }

  // ── Blank, or to a counselor ────────────────────────────────
  let to = params.to ?? "";
  let cc = params.cc ?? "";
  const subject = params.subject ?? "";
  let about = "";

  if (params.counselor) {
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
      <RecordHeader
        back={{ href: "/mail", label: "Mail" }}
        title="New message"
        standing={about || "From your own Outlook, when you press Send"}
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
