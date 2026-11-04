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

/**
 * The provider's own id for the message, wherever they put it.
 *
 * Searched by name at any depth rather than at a fixed path, because the two
 * real replies that came through carried no id under any of the obvious
 * names and there was nothing kept to look at. The payload is stored now, so
 * the next one settles this from evidence — until then this casts a slightly
 * wider net, and null is an honest answer.
 */
/**
 * A picture sent with the text (1b).
 *
 * By shape, not by key name. All 238 inbound texts on file kept their payload
 * and **not one has a media key of any kind** - so there is nothing to learn
 * GoHighLevel's name for it from, and a list of five names guessed off other
 * providers would be five guesses in a position of authority.
 *
 * What a media URL looks like is knowable without that: a string that is a
 * URL, under a key that reads like media, at any depth. The first real
 * picture message is either read correctly or arrives with its payload kept -
 * which is where every other field in this webhook already stands.
 */
const MEDIA_KEY = /attach|media|image|photo|picture|file/i;
const URLISH = /^https?:\/\/\S+$/i;

function findMedia(value: unknown, depth = 0, underMediaKey = false): string | null {
  if (depth > 5 || value === null || value === undefined) return null;

  if (typeof value === "string") {
    return underMediaKey && URLISH.test(value.trim()) ? value.trim() : null;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findMedia(item, depth + 1, underMediaKey);
      if (found) return found;
    }
    return null;
  }
  if (typeof value !== "object") return null;

  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    const found = findMedia(nested, depth + 1, underMediaKey || MEDIA_KEY.test(key));
    if (found) return found;
  }
  return null;
}

function findMessageId(value: unknown, depth = 0): string | null {
  if (depth > 4 || !value || typeof value !== "object") return null;
  const obj = value as Record<string, unknown>;

  for (const key of ["messageId", "smsMessageId", "message_id", "sms_message_id"]) {
    const found = obj[key];
    if (typeof found === "string" && found.trim()) return found.trim();
  }

  for (const nested of Object.values(obj)) {
    const found = findMessageId(nested, depth + 1);
    if (found) return found;
  }

  return null;
}

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
    p_provider_id: findMessageId(body) ?? (pick(body, ["id"]) || null),
    // The picture, where there is one (1b). Referenced: the media stays on the
    // provider's side with the provider's retention, and a copy here would be
    // a second place a client's photograph lives.
    p_media: findMedia(body),
    p_media_type: pick(body, ["mediaType", "media_type", "contentType", "content_type"]) || null,
    // Kept verbatim. What a provider sends is theirs to change, and the row it
    // arrived on is the only place the change will be visible afterwards.
    p_payload: body as never,
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
