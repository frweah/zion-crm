import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { corsHeaders, hashAddress, newSessionToken, readString } from "@/lib/web-chat";

/**
 * A contact form on zionvocrehab.com, sent.
 *
 * It arrives the way a website chat does, because it is one: somebody on the
 * website with a question who left a way to reach them. start_web_chat (0107)
 * already does everything a form needs - it refuses a machine that has sent
 * five in an hour, attaches the conversation to the client the phone number
 * or email already belongs to, keeps the line they agreed to word for word,
 * and raises a task when nobody is online to answer. This route reuses it
 * rather than growing a second door with its own rules.
 *
 * What the form says is posted as the visitor's first message, so whoever
 * opens the conversation reads it in one place. Nobody outside the website
 * is given a token: the reply happens by phone, email or text from the CRM.
 *
 * Unknown senders are not made into clients here. They wait in the inbox to
 * be matched, made into a referral, or marked spam, the same as an unknown
 * number since 0105 - a public form that writes client records is a form
 * anybody can fill the caseload with.
 */
export const dynamic = "force-dynamic";

export async function OPTIONS(request: NextRequest) {
  const cors = corsHeaders(request.headers.get("origin"));
  return cors ? new NextResponse(null, { status: 204, headers: cors }) : new NextResponse(null, { status: 403 });
}

const FORM_LABELS: Record<string, string> = {
  contact: "Contact form",
  employer: "Employer request",
};

export async function POST(request: NextRequest) {
  const cors = corsHeaders(request.headers.get("origin"));
  if (!cors) return NextResponse.json({ error: "Not a site this form serves." }, { status: 403 });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ error: "We could not read that." }, { status: 400, headers: cors });
  }

  // The field no person sees. A machine filling in every input fills this one.
  if (readString(body.website, 200) !== "") {
    return NextResponse.json({ error: "We could not send that." }, { status: 400, headers: cors });
  }

  const form = readString(body.form, 20) === "employer" ? "employer" : "contact";
  const phone = readString(body.phone, 40);
  const email = readString(body.email, 120);
  const consent = readString(body.consent, 400);

  const name =
    form === "employer"
      ? readString(body.contact_name, 80)
      : `${readString(body.first_name, 40)} ${readString(body.last_name, 40)}`.trim();

  // One way to reach them is what matches them to a record; the phone number
  // first, because that is what client records are most often keyed by.
  const contact = phone || email;

  const lines: string[] = [FORM_LABELS[form]];
  const add = (label: string, value: string) => {
    if (value) lines.push(`${label}: ${value}`);
  };
  if (form === "employer") {
    add("Company", readString(body.company, 120));
    add("Contact", name);
    add("Phone", phone);
    add("Email", email);
    add("Candidates", readString(body.candidates, 400));
    add("Role", readString(body.role, 120));
    add("Location", readString(body.location, 120));
  } else {
    add("Phone", phone);
    add("Email", email);
    add("I am", readString(body.role, 80));
    add("Interested in", readString(body.interest, 120));
    add("Agrees to text messages", readString(body.sms_consent, 10) === "yes" ? "Yes" : "No");
  }
  const message = readString(body.message, 1500);
  if (message) lines.push("", message);

  const { hash } = newSessionToken();
  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("start_web_chat", {
    p_name: name,
    p_contact: contact,
    p_consent: consent,
    p_token_hash: hash,
    p_ip_hash: hashAddress(request),
  });

  const row = data?.[0];
  if (error || !row?.conversation_id) {
    // The database's refusals are written for the person reading them.
    return NextResponse.json({ error: error?.message ?? "We could not send that." }, { status: 400, headers: cors });
  }

  const { error: postError } = await supabase.rpc("post_visitor_message", {
    p_conversation: row.conversation_id,
    p_body: lines.join("\n").slice(0, 2000),
  });
  if (postError) {
    return NextResponse.json({ error: postError.message }, { status: 400, headers: cors });
  }

  return NextResponse.json(
    { ok: true, promise: row.promise ?? "" },
    { status: 200, headers: { ...cors, "cache-control": "no-store" } },
  );
}
