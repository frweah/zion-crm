import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { fileByName } from "@/lib/file-by-name";

/**
 * File everything waiting in Admin → Documents.
 *
 * Owner decision, 10 Oct 2026: clear the queue in bulk, no per-file questions.
 * 133 documents had been waiting, and most were paper for records that already
 * exist - 67 of the 79 waiting authorization documents belonged to clients who
 * already had authorizations on file.
 *
 * It runs the same rules the agent runs on arrival (lib/file-by-name.ts) and
 * decides nothing of its own. That is the whole design: whatever happens to
 * the backlog here is what happens to the next arrival, so the queue cannot
 * refill with the same thing. The rules themselves changed - what they used to
 * only *propose* they now file - and both callers got that change at once
 * because there is one copy of them.
 *
 * A route rather than a script because the rules import through the app's own
 * aliases and `server-only`; they run inside Next or not at all. It is also
 * the honest home for it: if the queue ever backs up again this is one call,
 * and `?dry=1` says what it would do without doing it.
 *
 * Nothing here creates an authorization, an invoice or an amount. A document
 * named as an authorization that is not on file is filed *and* counted, and
 * one task is raised naming those clients - one task, not 133 questions.
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" "https://APP/api/cron/file-the-queue?dry=1"
 */
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function POST(request: NextRequest) {
  return handle(request);
}

export async function GET(request: NextRequest) {
  return handle(request);
}

async function handle(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  const provided =
    request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ??
    request.nextUrl.searchParams.get("secret");
  if (!secret || provided !== secret) {
    return NextResponse.json({ error: "Not authorised." }, { status: 401 });
  }

  const dry = request.nextUrl.searchParams.get("dry") === "1";
  const limit = Math.min(Math.max(Number(request.nextUrl.searchParams.get("limit")) || 200, 1), 500);
  const admin = createAdminClient();

  const { data: waiting, error } = await admin
    .from("inbox_documents")
    .select(
      "id, kind, state, client_id, parsed, proposal, filename, file_modified, storage_path, folder_name, ocr_text",
    )
    .eq("state", "Pending")
    .order("folder_name")
    .limit(limit);

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const buckets: Record<string, number> = {};
  const bump = (k: string) => (buckets[k] = (buckets[k] ?? 0) + 1);

  const needsAPerson: { folder: string; filename: string }[] = [];
  const noClient: { folder: string; filename: string; kind: string }[] = [];

  for (const doc of waiting ?? []) {
    // ── no client for its folder: it cannot be filed to anybody ──
    if (!doc.client_id) {
      noClient.push({
        folder: doc.folder_name ?? "(no folder)",
        filename: doc.filename ?? "",
        kind: doc.kind ?? "",
      });
      bump("needs a person");
      continue;
    }

    if (dry) {
      bump(`would file (${doc.kind})`);
      continue;
    }

    const result = await fileByName(admin, {
      doc,
      text: doc.ocr_text ?? "",
      fields: {},
      ocr: null,
    });
    bump(result.action);
    if (result.needsAPerson) {
      needsAPerson.push({ folder: doc.folder_name ?? "", filename: doc.filename ?? "" });
    }
  }

  // ── the one thing a person still has to decide ──────────────
  const clients = [...new Set(needsAPerson.map((d) => d.folder))];
  let raised: string | null = null;
  if (!dry && clients.length) {
    const { data: settings } = await admin
      .from("org_settings")
      .select("intake_staff_id")
      .limit(1)
      .maybeSingle();
    if (settings?.intake_staff_id) {
      const { error: told } = await admin.rpc("notify_person", {
        p_staff: settings.intake_staff_id,
        p_kind: "authorization_missing",
        p_text:
          `${needsAPerson.length} document(s) across ${clients.length} client(s) were filed from the ` +
          `documents folder and name an authorization that is not on file: ${clients.join(", ")}. ` +
          `The paper is on each client; somebody has to decide whether an authorization is owed.`,
        p_ref: "documents-folder-backfill",
        p_href: "/admin/documents",
        p_client: null,
        p_task_title: `Check ${clients.length} client(s) whose filed documents name an authorization not on file`,
        p_due: null,
        p_level: "warn",
        p_source: null,
      });
      raised = told ? told.message : "one task for intake";
    }
  }

  const { count } = await admin
    .from("inbox_documents")
    .select("id", { count: "exact", head: true })
    .eq("state", "Pending");

  return NextResponse.json({
    dry,
    looked_at: waiting?.length ?? 0,
    buckets,
    needs_a_person: noClient,
    named_an_authorization_not_on_file: { documents: needsAPerson.length, clients },
    raised,
    left_waiting: count ?? null,
  });
}
