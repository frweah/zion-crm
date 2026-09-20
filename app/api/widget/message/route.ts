import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { corsHeaders, hashToken, readString } from "@/lib/web-chat";

/**
 * What the visitor typed next.
 *
 * The token names the conversation; nothing in the body does. A visitor
 * cannot address a conversation that is not theirs because they have no way
 * to name one - the id never leaves this server.
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

  const token = readString(body.token, 128);
  const text = readString(body.body, 2000);
  if (!token) return NextResponse.json({ error: "This chat has closed. Please start a new one." }, { status: 401, headers: cors });

  const supabase = createAdminClient();
  const { data: conversation } = await supabase.rpc("web_chat_session", { p_token_hash: hashToken(token) });
  if (!conversation) {
    return NextResponse.json({ error: "This chat has closed. Please start a new one." }, { status: 401, headers: cors });
  }

  const { error } = await supabase.rpc("post_visitor_message", { p_conversation: conversation, p_body: text });
  if (error) return NextResponse.json({ error: error.message }, { status: 400, headers: cors });

  return NextResponse.json({ ok: true }, { status: 200, headers: { ...cors, "cache-control": "no-store" } });
}
