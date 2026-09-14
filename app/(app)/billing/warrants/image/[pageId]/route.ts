import { NextResponse } from "next/server";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { CAN_EDIT_BILLING } from "@/lib/constants";

/**
 * A warrant page, as the agent kept it: a short-lived link to the image in the
 * private warrants bucket, made for whoever asked. Linked from every screen
 * that shows a payment read from a warrant, so the stub is one click from the
 * money.
 *
 * The storage policy lets only Admin and Billing sign the link; this checks the
 * same thing first so anyone else gets a plain "not found" rather than an error.
 */
export async function GET(_request: Request, { params }: { params: Promise<{ pageId: string }> }) {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return new NextResponse("Not found.", { status: 404 });
  }

  const { pageId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(pageId)) return new NextResponse("Not found.", { status: 404 });

  const supabase = await createClient();
  const { data: page } = await supabase.from("warrant_pages").select("image_path").eq("id", pageId).maybeSingle();
  if (!page?.image_path) {
    return new NextResponse("No page image was kept for this warrant.", { status: 404 });
  }

  const { data: signed } = await supabase.storage.from("warrants").createSignedUrl(page.image_path, 300);
  if (!signed?.signedUrl) return new NextResponse("The page image could not be opened.", { status: 404 });

  return NextResponse.redirect(signed.signedUrl);
}
