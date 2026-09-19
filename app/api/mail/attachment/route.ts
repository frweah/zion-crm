import { NextResponse, type NextRequest } from "next/server";
import { myMailAccess, resolveMailbox } from "@/lib/mail-access";
import { fetchAttachment } from "@/lib/mail";

/**
 * An attachment, from Microsoft straight to the person's browser (Messaging
 * brief, M). Read with their own token - Microsoft decides whether they may -
 * and never written anywhere on the way. A shared mailbox is opened only if it
 * is one they are offered (resolveMailbox).
 */
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const access = await myMailAccess();
  if (!access.ok) return NextResponse.json({ error: access.message }, { status: 401 });

  const q = request.nextUrl.searchParams;
  const mailbox = resolveMailbox(access, q.get("box"));
  if (mailbox === false) return NextResponse.json({ error: "Not your mailbox." }, { status: 403 });
  const messageId = q.get("m") ?? "";
  const attachmentId = q.get("a") ?? "";
  if (!messageId || !attachmentId) return NextResponse.json({ error: "Which attachment?" }, { status: 400 });

  const upstream = await fetchAttachment(access.token, mailbox, messageId, attachmentId);
  if (!upstream.ok || !upstream.body) {
    return NextResponse.json({ error: `Microsoft did not return it (${upstream.status}).` }, { status: upstream.status === 404 ? 404 : 502 });
  }

  // A download, never drawn inline: an attachment is somebody else's file.
  const name = (q.get("n") ?? "attachment").replace(/[^\w.\- ()]/g, "_").slice(0, 120) || "attachment";
  return new NextResponse(upstream.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": `attachment; filename="${name}"`,
      "Cache-Control": "no-store, private",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
