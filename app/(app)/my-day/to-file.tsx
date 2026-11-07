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
};

export type ClientOption = { id: string; name: string };

/**
 * To file (item E).
 *
 * Things the practice noticed and nobody has filed: an appointment in
 * somebody's Outlook, mail that names a client. Each one is a guess with the
 * reason for the guess beside it, and three answers - whose it was, whether it
 * happened, or that it is not worth keeping.
 *
 * Nothing here is on a client's record yet. Confirming is what writes the
 * contact-log entry, so a report cannot carry a thing nobody has looked at.
 */
export function ToFile({
  items,
  clients,
  waiting,
}: {
  items: FileItem[];
  clients: ClientOption[];
  // How many are waiting in all, which is not always how many are shown. The
  // screen reads sixty at a time; the mail backlog put seventy-eight into one
  // inbox on its first night, and a list that quietly stopped at sixty would
  // have had eighteen nobody knew about.
  waiting: number;
}) {
  const [open, setOpen] = useState<{ id: string; which: string } | null>(null);

  if (items.length === 0) return null;

  return (
    <section className="page-section">
      <h2 className="h2">
        To file
        {waiting > items.length ? ` — ${items.length} of ${waiting}` : ""}
      </h2>
      <ul className="day-list">
        {items.map((item) => (
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
