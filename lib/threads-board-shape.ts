/**
 * The client threads board's shape: its groups, its tiles, and the sentences
 * that turn a row into something a person can read.
 *
 * Separate from the screen for the reason `reports-board-shape` is separate
 * from the reports grid: the grid is a client component and this has to be
 * runnable by a check. Every tile is a question about one row, asked here
 * once, so the number on a tile and the rows it filters to are the same
 * arithmetic run twice and cannot disagree.
 *
 * What a row is: one client, with every number and every channel folded in -
 * or one Friday draft waiting on somebody, or one person who is not a client
 * yet. Which of the three it is, `kind` says, and which group it belongs in
 * is decided by `client_threads_board` rather than here: the group is the
 * thing a verify script can put a fault in, and a screen that re-derived it
 * would be a second opinion nobody asked for.
 */

export type ThreadNumber = {
  phone: string;
  label: string;
  whose: string;
  whose_name: string;
  relationship: string;
  can_text: boolean;
  state: string;
  since: string | null;
};

export type ThreadRow = {
  row_key: string;
  /** needs-reply · approval · stuck · quiet · stranger · ok */
  grp: string;
  /** client · draft · stranger */
  kind: string;
  client_id: string | null;
  client_name: string | null;
  client_no: number | null;
  conversation_id: string | null;
  update_id: string | null;
  who: string;
  numbers: ThreadNumber[];
  channels: string[];
  last_at: string | null;
  last_channel: string | null;
  /**
   * The mirror's own two fields, handed through rather than read.
   *
   * What "from them" means is `lastLine` in lib/text-rows.ts and nowhere
   * else - the inbox, the client's record and this board all ask it, which is
   * what stops one text being described two ways. The board used to compute a
   * direction in SQL and check-text-rows was right to refuse it.
   */
  last_sender_kind: string | null;
  last_sender: string | null;
  last_body: string | null;
  last_status: string | null;
  last_media_url: string | null;
  /** Hours since they spoke, where nobody has answered on any channel. */
  waiting_hours: number | null;
  quiet_days: number | null;
  assigned_staff_id: string | null;
  assigned_name: string | null;
  unread: number;
  next_scheduled: string | null;
  next_update: string | null;
  failed: number;
  drafts: number;
  consent_missing: boolean;
  opted_out: boolean;
  can_text: boolean;
  status: string;
};

/** The groups, in the order a person works them. */
export const GROUPS = [
  { key: "needs-reply", label: "Needs a reply" },
  { key: "approval", label: "Waiting on your approval" },
  { key: "stuck", label: "Failed or stuck" },
  { key: "quiet", label: "Quiet 14+ days" },
  { key: "stranger", label: "Not a client yet" },
  { key: "ok", label: "Up to date" },
] as const;

/** Up to date is folded away: it is the record, not the work. */
export const CLOSED_GROUPS: string[] = ["ok"];

export type Tile = {
  key: string;
  label: string;
  holds: (r: ThreadRow) => boolean;
};

/**
 * The six tiles, which are filters and not counts.
 *
 * Unanswered takes the strangers in as well as the clients: somebody who
 * texted the practice and is not on anybody's record is the person most
 * likely to be left, and a tile that counted only clients would hide exactly
 * them. Consent missing and Opted out are about clients - a website chat has
 * no number to have agreed to anything.
 */
export const TILES: Tile[] = [
  {
    key: "unanswered",
    label: "Unanswered",
    holds: (r) => r.waiting_hours !== null,
  },
  { key: "drafts", label: "Drafts to approve", holds: (r) => r.kind === "draft" },
  { key: "stuck", label: "Failed or stuck", holds: (r) => r.failed > 0 },
  { key: "quiet", label: "Quiet 14+ days", holds: (r) => r.grp === "quiet" },
  {
    key: "consent",
    label: "Consent missing",
    holds: (r) => r.kind === "client" && r.consent_missing,
  },
  { key: "optout", label: "Opted out (STOP)", holds: (r) => r.opted_out },
];

/**
 * How long they have been waiting, in words.
 *
 * Rounded down and never more precise than it is useful: "4 days" is what
 * somebody acts on, and "4 days 7 hours" is the same sentence with a number
 * in it nobody reads. Under an hour it says minutes, because the difference
 * between ten minutes and fifty is the difference between answering now and
 * apologising.
 */
export function waited(hours: number | null): string {
  if (hours === null || hours < 0) return "";
  if (hours < 1) return "under an hour";
  if (hours < 24) return `${Math.floor(hours)} ${Math.floor(hours) === 1 ? "hour" : "hours"}`;
  const days = Math.floor(hours / 24);
  return `${days} ${days === 1 ? "day" : "days"}`;
}

/** The numbers, as the column draws them: the consent dot and whose it is. */
export function dots(r: ThreadRow): { number: ThreadNumber; tone: "ok" | "bad" | "none"; title: string }[] {
  return (r.numbers ?? []).map((n) => ({
    number: n,
    tone: n.can_text ? "ok" : n.state === "Withdrawn" ? "bad" : "none",
    title: n.can_text
      ? `${n.whose_name || n.whose} agreed${n.since ? ` on ${n.since.slice(0, 10)}` : ""}`
      : n.state === "Withdrawn"
        ? `${n.whose_name || n.whose} replied STOP`
        : `${n.whose_name || n.whose} has not agreed to be texted here`,
  }));
}

/**
 * Whether a number can be sent to, and why not where it cannot.
 *
 * The same question the database answers on the way in, asked here only so
 * the box can say so before somebody types. It is not the decision - the
 * decision is `sms_outgoing_requires_consent`, and this screen passes its
 * refusal through unchanged.
 */
export function whyNot(n: ThreadNumber | null): string | null {
  if (!n) return "There is no number on this record.";
  if (n.can_text) return null;
  if (n.state === "Withdrawn") {
    return `${n.whose_name || "They"} replied STOP, so nothing can be sent to this number. Log a call instead.`;
  }
  return `${n.whose_name || "They"} has not agreed to be texted at this number. Record their consent on the record first, or log a call instead.`;
}

/** The number a reply would go to: the client's own where it can be. */
export function sendingTo(r: ThreadRow): ThreadNumber | null {
  const numbers = r.numbers ?? [];
  return (
    numbers.find((n) => n.whose === "Client" && n.can_text) ??
    numbers.find((n) => n.can_text) ??
    numbers.find((n) => n.whose === "Client") ??
    numbers[0] ??
    null
  );
}

/** One line of the last message, for the row. */
export function firstLine(body: string | null, limit = 90): string {
  const line = (body ?? "").split("\n").find((l) => l.trim().length > 0) ?? "";
  const clean = line.trim();
  return clean.length > limit ? `${clean.slice(0, limit - 1)}…` : clean;
}

/** Which roles may send a text, which is the policy on `sms_messages`. */
export const CAN_SEND_TEXTS = ["Admin", "Job Search", "Reports"];

/**
 * Everybody who can open a client's record can log a call.
 *
 * Ruling 6c: a role the policy will refuse is not shown a send box. What it
 * is shown instead is the thing it can do - a job coach who rings a client
 * all day was being offered the one action the database would not take, and
 * had nowhere at all to put the call.
 */
export const CAN_LOG_CALLS = ["Admin", "Job Search", "Reports", "Job Coach", "Case Manager"];
