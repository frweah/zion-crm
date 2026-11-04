import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";

/**
 * What happened to a text after GoHighLevel took it.
 *
 * The practice used to learn one thing about an outgoing text - whether
 * GoHighLevel accepted it - and nothing afterwards. Accepting is not
 * delivering, so 'Delivered' was unknowable and a text the carrier dropped an
 * hour later went on reading as sent. This is the answer coming back (0287).
 *
 * Nothing is trusted from the body except the provider's own message id and
 * its status word. There is no client in it and no phone number in it: a
 * webhook that could name a client would be a way to write on somebody's
 * record over HTTP, and the id already says which row this is about.
 *
 * Set it up in GoHighLevel as a workflow webhook on outbound message status,
 * with a custom header:  x-zion-secret: <GHL_WEBHOOK_SECRET>
 *
 * It answers 200 to anything it can read, including a status for a message the
 * practice has no row for - a text sent from GoHighLevel's own screens is not
 * an error here, and a 400 would have the provider retrying it for ever.
 */
export const dynamic = "force-dynamic";

/** The provider's id for the message, wherever this workflow puts it. */
function findMessageId(value: unknown, depth = 0): string | null {
  if (depth > 4 || !value || typeof value !== "object") return null;
  const obj = value as Record<string, unknown>;

  for (const key of ["messageId", "smsMessageId", "message_id", "sms_message_id", "id"]) {
    const found = obj[key];
    if (typeof found === "string" && found.trim()) return found.trim();
  }
  for (const nested of Object.values(obj)) {
    const found = findMessageId(nested, depth + 1);
    if (found) return found;
  }
  return null;
}

/** The status word, likewise. */
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
  if (presented.length !== secret.length || !timingSafeEqual(presented, secret)) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ error: "Expected JSON." }, { status: 400 });
  }

  const providerId = findMessageId(body);
  const status = pick(body, [
    "status",
    "messageStatus",
    "message_status",
    "message.status",
    "deliveryStatus",
    "delivery_status",
  ]);

  if (!providerId) {
    return NextResponse.json({ error: "No message id in that payload." }, { status: 400 });
  }
  if (!status) {
    return NextResponse.json({ error: "No status in that payload." }, { status: 400 });
  }

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("record_text_status", {
    p_provider_id: providerId,
    p_status: status,
    p_error: pick(body, ["error", "errorMessage", "message.error", "reason"]) || null,
    // Kept verbatim. What a provider sends is theirs to change, and the row it
    // arrived on is the only place the change will be visible afterwards.
    p_payload: body as never,
  });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  const row = Array.isArray(data) ? data[0] : data;
  return NextResponse.json({ matched: Boolean(row?.matched), status: row?.status ?? null });
}

function timingSafeEqual(a: string, b: string): boolean {
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
