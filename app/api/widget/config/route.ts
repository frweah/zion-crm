import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { corsHeaders } from "@/lib/web-chat";

/**
 * What the bubble needs before anybody has typed anything: whether it is
 * shown at all, whether somebody is there to answer, and the two lines of
 * copy the practice wrote.
 *
 * Nothing here is about a person, so there is nothing here to protect - but
 * it still only answers the sites the practice named, because a chat widget
 * embedded on somebody else's page would be a chat widget pretending to be
 * this practice.
 */
export const dynamic = "force-dynamic";

export async function OPTIONS(request: NextRequest) {
  const cors = corsHeaders(request.headers.get("origin"));
  return cors ? new NextResponse(null, { status: 204, headers: cors }) : new NextResponse(null, { status: 403 });
}

export async function GET(request: NextRequest) {
  const cors = corsHeaders(request.headers.get("origin"));
  if (!cors) return NextResponse.json({ error: "Not a site this chat serves." }, { status: 403 });

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("web_chat_config");
  const row = data?.[0];
  if (error || !row) {
    return NextResponse.json({ enabled: false }, { status: 200, headers: cors });
  }
  return NextResponse.json(
    {
      enabled: row.enabled ?? false,
      live: row.live ?? false,
      greeting: row.greeting ?? "",
      promise: row.promise ?? "",
    },
    { status: 200, headers: { ...cors, "cache-control": "no-store" } },
  );
}
