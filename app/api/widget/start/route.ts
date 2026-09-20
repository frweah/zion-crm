import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { corsHeaders, hashAddress, newSessionToken, readString } from "@/lib/web-chat";

/**
 * A visitor says who they are, and the conversation begins.
 *
 * The notice they agreed to is sent up with what they typed and stored word
 * for word, because "they consented" is not a thing a later screen should
 * have to take on trust - the line itself is on the record.
 *
 * Who it goes to, whether anybody is there, and whether that number is
 * already somebody's are all the database's answers (0107). This route
 * carries the message and mints the token; it decides nothing.
 */
export const dynamic = "force-dynamic";

export async function OPTIONS(request: NextRequest) {
  const cors = corsHeaders(request.headers.get("origin"));
  return cors ? new NextResponse(null, { status: 204, headers: cors }) : new NextResponse(null, { status: 403 });
}

export async function POST(request: NextRequest) {
  const cors = corsHeaders(request.headers.get("origin"));
  if (!cors) return NextResponse.json({ error: "Not a site this chat serves." }, { status: 403 });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ error: "We could not read that." }, { status: 400, headers: cors });
  }

  // A field no person sees and no person fills in. A machine filling in every
  // input it finds fills this one too, and says so about itself.
  if (readString(body.website, 200) !== "") {
    return NextResponse.json({ error: "We could not start that chat." }, { status: 400, headers: cors });
  }

  const name = readString(body.name, 80);
  const contact = readString(body.contact, 120);
  const consent = readString(body.consent, 400);
  const first = readString(body.message, 2000);

  const { token, hash } = newSessionToken();
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
    return NextResponse.json({ error: error?.message ?? "We could not start that chat." }, { status: 400, headers: cors });
  }

  if (first) {
    await supabase.rpc("post_visitor_message", { p_conversation: row.conversation_id, p_body: first });
  }

  return NextResponse.json(
    {
      token,
      live: row.live ?? false,
      promise: row.promise ?? "",
      answering: row.assigned_name ? row.assigned_name.split(" ")[0] : "",
    },
    { status: 200, headers: { ...cors, "cache-control": "no-store" } },
  );
}
