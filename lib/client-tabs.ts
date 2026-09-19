/**
 * The client record's tabs, and where the old ones went.
 *
 * Twelve tabs became six in the consolidation (September 2026): a screen with
 * more than six tabs is two screens, and an action - add a task, send a report
 * - is a button in the record's header, not a place. Nothing was removed; each
 * old tab lives on inside one of these, and an old link (a bookmark, a link in
 * an email, an alert written before the move) is redirected to it.
 *
 * scripts/check-nav.mjs asserts the six, that every old key is mapped, and that
 * no link in the code still points at an old one.
 */
export const CLIENT_TABS = [
  { key: "activity", label: "Activity" },
  { key: "profile", label: "Profile" },
  { key: "notes", label: "Notes" },
  { key: "jobs", label: "Jobs" },
  { key: "billing", label: "Billing" },
  { key: "documents", label: "Documents" },
  // The client's texts, both ways (Messaging brief, A; owner, 19 Sept 2026 -
  // a seventh tab, deliberately, rather than buried inside Activity).
  { key: "messages", label: "Messages" },
] as const;

export type ClientTab = (typeof CLIENT_TABS)[number]["key"];

/** The tabs merged in the consolidation, and where each one went. */
export const MOVED_CLIENT_TABS: Record<string, { tab: ClientTab; hash?: string; report?: boolean }> = {
  overview: { tab: "profile" },
  intake: { tab: "profile", hash: "intake" },
  tasks: { tab: "activity" },
  calendar: { tab: "activity" },
  placements: { tab: "jobs" },
  authorizations: { tab: "billing" },
  payments: { tab: "billing" },
  files: { tab: "documents" },
  forms: { tab: "documents" },
  // The progress report became the "Send report" dialog, opened over Documents.
  report: { tab: "documents", report: true },
};

export function isClientTab(key: string | null | undefined): key is ClientTab {
  return Boolean(key) && CLIENT_TABS.some((t) => t.key === key);
}

/** Where a tab key lands today - its own tab, the tab it moved into, or Activity. */
export function clientTabFor(key: string | null | undefined): ClientTab {
  if (isClientTab(key)) return key;
  if (key && MOVED_CLIENT_TABS[key]) return MOVED_CLIENT_TABS[key].tab;
  return "activity";
}
