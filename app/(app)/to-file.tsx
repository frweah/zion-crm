"use client";

import { useActionState, useState } from "react";
import { PRACTICE_TZ } from "@/lib/constants";
import { assignToFile, confirmToFile, discardToFile, type FileState } from "./to-file-actions";

const EMPTY: FileState = { error: null, ok: null };

/** The categories a contact can be about, as the notes already name them. */
const CATEGORIES = [
  "Job development",
  "Job placement",
  "Job coaching",
  "Job search",
  "Assessment",
  "Life skills",
  "General progress",
  "Personal",
] as const;

export type FileItem = {
  id: string;
  source: string;
  title: string;
  detail: string;
  happened_at: string | null;
  client_id: string | null;
  client_name: string | null;
  guess_why: string;
  /** Whose inbox it is in. Only set where the panel shows everybody's. */
  staff_name?: string | null;
};

export type ClientOption = { id: string; name: string };

/** The month an item will land in, which is the month it happened in. */
function landsIn(happenedAt: string | null): string {
  const when = happenedAt ? new Date(happenedAt) : new Date();
  return when.toLocaleDateString("en-US", {
    timeZone: PRACTICE_TZ,
    month: "long",
    year: "numeric",
  });
}

/**
 * To file (item E), on My day and on the reports board.
 *
 * Things the practice noticed and nobody has filed: an appointment in
 * somebody's Outlook, mail that names a client. Each one is a guess with the
 * reason for the guess beside it, and three answers - whose it was, whether it
 * happened, or that it is not worth keeping.
 *
 * Nothing here is on a client's record yet. Confirming is what writes the
 * contact-log entry, so a report cannot carry a thing nobody has looked at.
 *
 * One component, two filters, and not two inboxes (owner, ruling 2 of 20
 * November 2026). On My day and on the phone it is each person's own, as it
 * always was. On the reports board it is everybody's, grouped by whose, for
 * Reports and Admin - of the 147 items waiting when the board was built, 106
 * were somebody else's, and every one of those was a line missing from a
 * month the reports manager is the person being asked about. Which filter is
 * which is the caller's business; `to_file`'s read policy and
 * `to_file_is_mine` decide what is allowed either way.
 *
 * Each item says which month filing it lands in, because filing keeps the
 * date the thing happened: an October appointment filed in November goes into
 * October's report, not into the month somebody is looking at.
 */
export function ToFile({
  items,
  clients,
  waiting,
  anchor,
  grouped = false,
  foldable = false,
}: {
  items: FileItem[];
  clients: ClientOption[];
  // How many are waiting in all, which is not always how many are shown. The
  // screen reads sixty at a time; the mail backlog put seventy-eight into one
  // inbox on its first night, and a list that quietly stopped at sixty would
  // have had eighteen nobody knew about.
  waiting: number;
  /** An id to link to, where a tile above points at the panel. */
  anchor?: string;
  /** Everybody's, under a line per person. */
  grouped?: boolean;
  /** Served folded, for a screen whose subject is below it. */
  foldable?: boolean;
}) {
  const [open, setOpen] = useState<{ id: string; which: string } | null>(null);
  const [shut, setShut] = useState(foldable);

  if (items.length === 0) return null;

  const whose = grouped
    ? [...new Set(items.map((i) => i.staff_name ?? ""))].sort()
    : [""];

  const heading = `To file${waiting > items.length ? ` — ${items.length} of ${waiting}` : ` (${waiting})`}`;

  const list = (only: string) => (
    <ul className="day-list">
      {items
        .filter((item) => !grouped || (item.staff_name ?? "") === only)
        .map((item) => (
          <li key={item.id} style={{ display: "block" }}>
            <div className="row2" style={{ gap: 8, alignItems: "baseline" }}>
              <span className="chip">{item.source}</span>
              <span className="day-main" style={{ flex: 1 }}>
                <b>{item.title}</b>
                <span className="lock">
                  {item.happened_at
                    ? ` ${new Date(item.happened_at).toLocaleString("en-US", {
                        timeZone: PRACTICE_TZ,
                        month: "short",
                        day: "numeric",
                        hour: "numeric",
                        minute: "2-digit",
                      })}`
                    : ""}
                  {item.detail ? ` · ${item.detail}` : ""}
                </span>
                <div className="lock">
                  {item.client_name
                    ? `${item.client_name} — ${item.guess_why}`
                    : "Nobody guessed — say who it was about"}
                  {` · lands in ${landsIn(item.happened_at)}`}
                </div>
              </span>
              <span className="record-actions">
                <Pick item={item} which="assign" open={open} setOpen={setOpen}>
                  {item.client_name ? "Somebody else" : "Assign to client"}
                </Pick>
                <Pick item={item} which="confirm" open={open} setOpen={setOpen}>
                  Confirm
                </Pick>
                <Pick item={item} which="discard" open={open} setOpen={setOpen}>
                  Discard
                </Pick>
              </span>
            </div>

            {open?.id === item.id && open.which === "assign" ? (
              <Assign item={item} clients={clients} />
            ) : null}
            {open?.id === item.id && open.which === "confirm" ? <Confirm item={item} /> : null}
            {open?.id === item.id && open.which === "discard" ? <Discard item={item} /> : null}
          </li>
        ))}
    </ul>
  );

  return (
    <section className="page-section" id={anchor}>
      <h2 className="h2">
        {foldable ? (
          <button
            type="button"
            className="toggle"
            aria-expanded={!shut}
            onClick={() => setShut((v) => !v)}
          >
            {shut ? "▸" : "▾"} {heading}
          </button>
        ) : (
          heading
        )}
      </h2>
      {!shut &&
        (grouped
          ? whose.map((who) => (
              <div key={who || "nobody"}>
                <div className="lock" style={{ marginTop: 8 }}>
                  {who || "nobody"} — {items.filter((i) => (i.staff_name ?? "") === who).length}
                </div>
                {list(who)}
              </div>
            ))
          : list(""))}
    </section>
  );
}

function Said({ state }: { state: FileState }) {
  if (state.error) return <p className="alert bad">{state.error}</p>;
  if (state.ok) return <p className="alert ok">{state.ok}</p>;
  return null;
}

function Pick({
  item,
  which,
  open,
  setOpen,
  children,
}: {
  item: FileItem;
  which: string;
  open: { id: string; which: string } | null;
  setOpen: (v: { id: string; which: string } | null) => void;
  children: React.ReactNode;
}) {
  const here = open?.id === item.id && open.which === which;
  return (
    <button
      type="button"
      className={here ? "btn" : "btn ghost"}
      onClick={() => setOpen(here ? null : { id: item.id, which })}
    >
      {children}
    </button>
  );
}

/**
 * Whose it was, found by typing.
 *
 * A select of every client is a scroll of several hundred, which is the
 * reason the billing form stopped being one.
 */
function Assign({ item, clients }: { item: FileItem; clients: ClientOption[] }) {
  const [state, action, pending] = useActionState(assignToFile, EMPTY);
  const [find, setFind] = useState("");
  const [chosen, setChosen] = useState<ClientOption | null>(null);
  const matching =
    find.trim().length < 2
      ? []
      : clients.filter((c) => c.name.toLowerCase().includes(find.trim().toLowerCase())).slice(0, 8);

  return (
    <form action={action} style={{ marginTop: 8 }}>
      <input type="hidden" name="item" value={item.id} />
      <Said state={state} />
      {chosen ? (
        <div className="row2" style={{ gap: 8, alignItems: "center" }}>
          <input type="hidden" name="client_id" value={chosen.id} />
          <b>{chosen.name}</b>
          <button type="button" className="btn ghost" onClick={() => setChosen(null)}>
            Somebody else
          </button>
          <button className="btn" type="submit" disabled={pending}>
            {pending ? "…" : "Assign it"}
          </button>
        </div>
      ) : (
        <>
          <label className="field">
            Client
            <input
              type="search"
              value={find}
              onChange={(e) => setFind(e.target.value)}
              placeholder="Start typing a name"
              autoComplete="off"
            />
          </label>
          {matching.length > 0 && (
            <div className="file-targets" style={{ marginTop: 4 }}>
              {matching.map((c) => (
                <button key={c.id} type="button" className="file-target" onClick={() => setChosen(c)}>
                  <span>{c.name}</span>
                </button>
              ))}
            </div>
          )}
          {find.trim().length >= 2 && matching.length === 0 && (
            <p className="empty" style={{ margin: "4px 0 0" }}>
              Nobody matches that.
            </p>
          )}
        </>
      )}
    </form>
  );
}

/** Happened, did not happen, or the wrong client. */
function Confirm({ item }: { item: FileItem }) {
  const [state, action, pending] = useActionState(confirmToFile, EMPTY);
  return (
    <form action={action} style={{ marginTop: 8 }}>
      <input type="hidden" name="item" value={item.id} />
      <Said state={state} />
      <div className="row2" style={{ gap: 8, alignItems: "flex-end" }}>
        <label className="field" style={{ flex: 2 }}>
          What to put on the record
          <input name="note" placeholder="One line, if there is anything to add" autoComplete="off" />
        </label>
        <label className="field" style={{ maxWidth: 200 }}>
          About
          <select name="category" defaultValue="">
            <option value="">—</option>
            {CATEGORIES.map((c) => (
              <option key={c}>{c}</option>
            ))}
          </select>
        </label>
      </div>
      <div className="record-actions" style={{ marginTop: 8 }}>
        <button className="btn" name="outcome" value="happened" disabled={pending}>
          It happened
        </button>
        <button className="btn ghost" name="outcome" value="did not happen" disabled={pending}>
          It did not happen
        </button>
        <button className="btn ghost" name="outcome" value="wrong client" disabled={pending}>
          Wrong client
        </button>
      </div>
    </form>
  );
}

function Discard({ item }: { item: FileItem }) {
  const [state, action, pending] = useActionState(discardToFile, EMPTY);
  return (
    <form action={action} style={{ marginTop: 8 }}>
      <input type="hidden" name="item" value={item.id} />
      <Said state={state} />
      <div className="row2" style={{ gap: 8, alignItems: "flex-end" }}>
        <label className="field" style={{ flex: 1 }}>
          Why, if it is worth saying
          <input name="reason" autoComplete="off" />
        </label>
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "…" : "Discard"}
        </button>
      </div>
    </form>
  );
}
