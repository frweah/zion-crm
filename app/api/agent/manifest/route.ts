import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";

/**
 * What the agent found, and what of it we want.
 *
 * The agent lists the folder and sends hashes; this answers with the ones it
 * has never seen. A backfill of two thousand files is then one small request
 * and however many uploads are actually new — rather than two thousand
 * uploads to find out.
 *
 * It also records that a run happened, so "is it still running?" is a
 * question the CRM can answer without going to the machine. A run that finds
 * nothing new still says it ran, which is the run you most want to see.
 */
export const dynamic = "force-dynamic";

type Entry = { hash: string; path: string; folder: string; size?: number; modified?: string };

export async function POST(request: NextRequest) {
  const secret = process.env.AGENT_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "AGENT_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("x-zion-agent") !== secret) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let body: { files?: Entry[]; machine?: string; version?: string; error?: string };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Expected JSON." }, { status: 400 });
  }

  const files = Array.isArray(body.files) ? body.files : [];
  const hashes = [...new Set(files.map((f) => f.hash).filter(Boolean))];

  const supabase = createAdminClient();

  const { data, error } = await supabase.rpc("inbox_seen", {
    p_hashes: hashes as never,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const known = new Set(
    (data ?? []).filter((r) => r.known).map((r) => r.sha256 as string),
  );
  const wanted = hashes.filter((h) => !known.has(h));

  await supabase.from("inbox_runs").insert({
    machine: (body.machine ?? "").slice(0, 80),
    agent_version: (body.version ?? "").slice(0, 20),
    files_seen: files.length,
    files_new: wanted.length,
    folders_seen: new Set(files.map((f) => f.folder)).size,
    error: (body.error ?? "").slice(0, 300),
  });

  return NextResponse.json({ wanted });
}
