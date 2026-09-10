import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";

/**
 * A client texting back.
 *
 * GoHighLevel posts here when a message arrives on the practice line. The
 * reply is written down and, if it says STOP, consent is withdrawn — by the
 * database function, not by this route. That matters: a withdrawal must not
 * depend on whether the code that received it remembered to act on it.
 *
 * Nothing is trusted from the body except the number and the text. There is
 * no client id in it and there is no consent flag in it; a webhook that could
 * say "this person consented" would be a way to grant consent by HTTP.
 *
 * Set it up in GoHighLevel as a workflow webhook on inbound messages, with a
 * custom header:  x-zion-secret: <GHL_WEBHOOK_SECRET>
 */
export const dynamic = "force-dynamic";

/** GoHighLevel's payloads vary by workflow. Look where the number could be. */
function pick(body: Record<string, unknown>, keys: string[]): string {
  for (const key of keys) {
    const parts = key.split(".");
    let value: unknown = body;
    for (const part of parts) {
      if (value && typeof value === "object" && part in (value as Record<string, unknown>)) {
        value = (value as Record<string, unknown>)[part];
      } else {
        value = undefined;
        break;
      }
    }
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

export async function POST(request: NextRequest) {
  const secret = process.env.GHL_WEBHOOK_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "GHL_WEBHOOK_SECRET is not set" }, { status: 500 });
  }

  const presented =
    request.headers.get("x-zion-secret") ?? request.nextUrl.searchParams.get("key") ?? "";

  // Constant time is beside the point against a network attacker, but it
  // costs nothing and the habit is worth keeping.
  if (presented.length !== secret.length || !timingSafeEqual(presented, secret)) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ error: "Expected JSON." }, { status: 400 });
  }

  // An outbound message echoed back is not a reply, and logging it would show
  // every reminder twice on the client's timeline.
  const direction = pick(body, ["direction", "message.direction", "messageDirection"]);
  if (direction && direction.toLowerCase() !== "inbound") {
    return NextResponse.json({ ignored: "not an inbound message" });
  }

  const phone = pick(body, [
    "phone",
    "from",
    "contact_phone",
    "contactPhone",
    "message.from",
    "sms.from",
  ]);
  const text = pick(body, ["message", "body", "message.body", "sms.body", "text"]);

  if (!phone) {
    return NextResponse.json({ error: "No phone number in that payload." }, { status: 400 });
  }

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("record_incoming_sms", {
    p_phone: phone,
    p_body: text,
    p_provider_id: pick(body, ["messageId", "message.id", "id"]) || null,
  });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  const row = Array.isArray(data) ? data[0] : data;
  return NextResponse.json({
    logged: true,
    matched: Boolean(row?.client_id),
    action: row?.action ?? "logged",
  });
}

function timingSafeEqual(a: string, b: string): boolean {
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
