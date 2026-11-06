"use client";

/**
 * What Team chat has open, for the one thing outside it that needs to know.
 *
 * The pop-up card already refuses to appear for a thread that is open on the
 * full page, by reading `?c=` out of the address. The compact window is not in
 * the address - it floats over whatever page somebody is on - so it has to say
 * where it is some other way, or a message would arrive as a card over the
 * window already showing it.
 *
 * A module rather than an event, because the pop-up reads this *inside* the
 * Realtime handler, which is installed once. A handler reading a React state
 * would read whatever that state was when it was installed, which is the stale
 * closure that makes a setting look as though it did nothing.
 *
 * "use client" so a server component cannot import it. Module state on the
 * server is shared by every request, which is how one person's open thread
 * would decide another person's pop-up.
 */

export type TeamOpen = {
  /** Whether a window is actually on the screen - not merely mounted. */
  visible: boolean;
  /** How it is presented: the right-hand pane, or the bubble's window. */
  mode: "pane" | "compact";
  /** The thread it is showing, or null for the list of threads. */
  threadId: string | null;
};

let open: TeamOpen = { visible: false, mode: "pane", threadId: null };
const listeners = new Set<() => void>();

export function setTeamOpen(next: TeamOpen): void {
  if (
    next.visible === open.visible &&
    next.mode === open.mode &&
    next.threadId === open.threadId
  ) {
    return;
  }
  open = next;
  listeners.forEach((l) => l());
}

/** Read at the moment it matters, which is what the Realtime handler needs. */
export function teamOpenNow(): TeamOpen {
  return open;
}

export function subscribeTeamOpen(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** For useSyncExternalStore on the server pass, where nothing is open. */
export const teamOpenClosed: TeamOpen = { visible: false, mode: "pane", threadId: null };
