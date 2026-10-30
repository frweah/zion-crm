import { redirect } from "next/navigation";

/**
 * Chat moved to Team (owner, 30 Oct 2026).
 *
 * The screen itself is `screen.tsx` beside this file, rendered by /team. This
 * is here for the links that already exist - a bookmark, a line in a note, the
 * pop-up anybody had open when it moved - and it carries the query string,
 * because ?c= is which thread somebody was sent to.
 */
export default async function MessagesPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (typeof value === "string") query.set(key, value);
  }
  const tail = query.toString();
  redirect(tail ? `/team?${tail}` : "/team");
}
