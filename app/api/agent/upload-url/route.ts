import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { INBOX_BUCKET, STORAGE_MAX_BYTES, inboxStoragePath, isSha256 } from "@/lib/inbox-storage";

/**
 * A one-use address to put a large file straight into storage.
 *
 * Vercel refuses any request body over 4.5 MB before this application sees
 * it — a 413 with nothing in our logs — so a scanned authorization of 8 MB
 * could never reach /api/agent/file however generous that route's own limit
 * was. For those, the agent asks here, PUTs the bytes to storage directly,
 * and then tells the file route to read them from there.
 *
 * Handing out an upload URL is safe because it is not trusted afterwards:
 * the file route downloads whatever landed at the path and recomputes its
 * hash. Bytes that are not the file this hash names are refused there, and
 * nothing is recorded.
 */
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  const secret = process.env.AGENT_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "AGENT_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("x-zion-agent") !== secret) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let body: { hash?: string; size?: number };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Expected JSON." }, { status: 400 });
  }

  const hash = String(body.hash ?? "").toLowerCase();
  if (!isSha256(hash)) {
    return NextResponse.json({ error: "A file is named by its SHA-256 hash." }, { status: 400 });
  }

  const size = Number(body.size ?? 0);
  if (size > STORAGE_MAX_BYTES) {
    return NextResponse.json(
      {
        error: `Over the ${STORAGE_MAX_BYTES / (1024 * 1024)} MB storage limit (${(size / (1024 * 1024)).toFixed(1)} MB).`,
      },
      { status: 413 },
    );
  }

  const supabase = createAdminClient();

  // Already held: say so, and hand out nothing.
  const { data: existing } = await supabase
    .from("inbox_documents")
    .select("id")
    .eq("sha256", hash)
    .maybeSingle();

  if (existing) return NextResponse.json({ already: true, id: existing.id });

  const { data, error } = await supabase.storage
    .from(INBOX_BUCKET)
    .createSignedUploadUrl(inboxStoragePath(hash), { upsert: true });

  if (error || !data) {
    return NextResponse.json(
      { error: `No upload address: ${error?.message ?? "unknown"}` },
      { status: 500 },
    );
  }

  return NextResponse.json({ signedUrl: data.signedUrl, path: data.path });
}
