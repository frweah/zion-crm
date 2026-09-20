import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { corsHeaders, hashToken } from "@/lib/web-chat";

/**
 * What has been said since the visitor last looked.
 *
 * Polling rather than a live socket: a visitor's browser holding an open
 * connection to the database would need a key of its own, and this whole
 * channel is built so that it never has one. A few seconds' wait for a reply
 * on a website is nobody's problem.
 *
 * Staff get their end live, as they always have (0104) - it is only the
 * visitor's end that polls.
 */
export const dynamic = "force-dynamic";

export async function OPTIONS(request: NextRequest) {
  const cors = corsHeaders(request.headers.get("origin"));
  return cors ? new NextResponse(null, { status: 204, headers: cors }) : new NextResponse(null, { status: 403 });
}

export async function GET(request: NextRequest) {
  const cors = corsHeaders(request.headers.get("origin"));
  if (!cors) return NextResponse.json({ error: "Not a site this chat serves." }, { status: 403 });

  const token = (request.nextUrl.searchParams.get("token") ?? "").slice(0, 128);
  const sinceRaw = Number(request.nextUrl.searchParams.get("since") ?? "0");
  const since = Number.isFinite(sinceRaw) && sinceRaw > 0 ? Math.floor(sinceRaw) : 0;
  if (!token) return NextResponse.json({ error: "This chat has closed." }, { status: 401, headers: cors });

  const supabase = createAdminClient();
  const { data: conversation } = await supabase.rpc("web_chat_session", { p_token_hash: hashToken(token) });
  if (!conversation) {
    return NextResponse.json({ error: "This chat has closed." }, { status: 401, headers: cors });
  }

  const { data } = await supabase.rpc("web_chat_thread", { p_conversation: conversation, p_since: since });
  return NextResponse.json(
    {
      messages: (data ?? []).map((m) => ({ seq: m.seq, who: m.who, from: m.sender_label, body: m.body })),
    },
    { status: 200, headers: { ...cors, "cache-control": "no-store" } },
  );
}
