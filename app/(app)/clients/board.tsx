"use client";

import { useActionState, useState, useTransition } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { STAGES, stageLabel, stageNote, stageToken, today } from "@/lib/constants";
import { moveClient, closeClient, deactivateClient, type BoardState } from "./board-actions";
import { recordAttachment, type FileState } from "./[id]/files/actions";

/** A type of document, as client_file_categories has it (0203). */
export type FileCategory = { key: string; label: string };

const FIFTY_MB = 52428800;

/**
 * The file's own fingerprint, so one client cannot hold the same bytes twice
 * (0202). Computed in the browser because that is where the bytes are, which
 * is the same reason the upload does not go through a server action.
 */
async function fingerprint(file: File): Promise<string> {
  try {
    const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  } catch {
    return "";
  }
}

/**
 * The caseload as a board (owner, 22 Oct 2026).
 *
 * Seven fixed columns in the order the work happens, one card per active
 * client under the stage they are in. The board is the Clients tab now; the
 * list it replaced is still there, a click away, as All clients.
 *
 * Three things are deliberately not decided here:
 *
 *   The chip on a card is never hand-set. It is the one alert the database
 *   already computes for that client's live authorizations - the same
 *   sentence the record screen and the working list show - so the board
 *   cannot tell somebody a different story from the other two.
 *
 *   A move cannot happen without a note. That is the database's rule, not
 *   the form's: the dialog asks, and the move is refused anyway if the note
 *   is empty, which is what makes it true of an import as well as of a drag.
 *
 *   Who may close is the database's too. The button is hidden from everybody
 *   else, which is courtesy rather than security.
 */
export type Card = {
  client_id: string;
  name: string;
  stage: string;
  goal: string | null;
  counselor: string | null;
  assigned_to: string | null;
  days_in_stage: number;
  services: string[];
  chip: string | null;
  chip_urgency: number | null;
  last_note: string | null;
  last_note_on: string | null;
};

const initial: BoardState = { error: null, ok: null };

/**
 * The two ways off the board, as menu values.
 *
 * Prefixed so they cannot collide with a stage name, now or when somebody
 * adds an eighth column.
 */
const OFF_INACTIVE = "off:inactive";
const OFF_CLOSE = "off:close";

/** The three words a chip gets, from the urgency the database gave it. */
const chipTone = (urgency: number | null) =>
  urgency === null ? "" : urgency <= 1 ? " bad" : urgency <= 4 ? " warn" : "";

export function ClientsBoard({
  cards,
  canClose,
  categories,
}: {
  cards: Card[];
  canClose: boolean;
  categories: FileCategory[];
}) {
  /**
   * Which column a phone is showing.
   *
   * Seven columns do not fit on a phone and never will, so below 640px one
   * is shown at a time and this picks it. Above that the picker is hidden
   * and every column is on screen, so the state costs nothing and there is
   * no second layout to keep right.
   */
  const [picked, setPicked] = useState<string>(STAGES[0]);
  const [dragging, setDragging] = useState<string | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const [panel, setPanel] = useState<Card | null>(null);
  const [moving, setMoving] = useState<{ card: Card; to: string } | null>(null);
  /**
   * Taking a card off the board, and which of the two ways.
   *
   * They are deliberately separate choices rather than one control with a
   * mode. Making somebody inactive files them; closing them ends the work
   * and takes their open authorizations with it. A single control that
   * changed what the button meant is how somebody closes a client they only
   * meant to tidy away.
   */
  const [removing, setRemoving] = useState<{ card: Card; how: "inactive" | "close" } | null>(null);

  const byStage = (stage: string) => cards.filter((c) => c.stage === stage);

  return (
    <>
      <label className="board-picker">
        <span className="lock">Stage</span>
        <select value={picked} onChange={(e) => setPicked(e.target.value)}>
          {STAGES.map((s) => (
            <option key={s} value={s}>
              {stageLabel(s)} ({cards.filter((c) => c.stage === s).length})
            </option>
          ))}
        </select>
      </label>

      <div className="board">
        {STAGES.map((stage) => {
          const column = byStage(stage);
          const accent = `var(${stageToken(stage)})`;
          return (
            <section
              key={stage}
              className={
                "board-column" +
                (over === stage ? " over" : "") +
                (picked === stage ? " is-picked" : "")
              }
              onDragOver={(e) => {
                e.preventDefault();
                setOver(stage);
              }}
              onDragLeave={() => setOver((s) => (s === stage ? null : s))}
              onDrop={(e) => {
                e.preventDefault();
                setOver(null);
                const card = cards.find((c) => c.client_id === dragging);
                setDragging(null);
                if (card && card.stage !== stage) setMoving({ card, to: stage });
              }}
            >
              <header className="board-head" style={{ borderTopColor: accent }}>
                <h2 className="board-title" style={{ color: accent }}>
                  {stageLabel(stage)} <span className="board-count">{column.length}</span>
                </h2>
                <p className="lock">{stageNote(stage)}</p>
              </header>

              <div className="board-cards">
                {column.map((c) => (
                  <article
                    key={c.client_id}
                    className="board-card"
                    style={{ borderLeftColor: accent }}
                    draggable
                    onDragStart={() => setDragging(c.client_id)}
                    onDragEnd={() => setDragging(null)}
                  >
                    <button type="button" className="board-open" onClick={() => setPanel(c)}>
                      <span className="board-name">{c.name}</span>
                      {c.goal && <span className="lock board-goal">{c.goal}</span>}
                    </button>

                    <p className="lock board-who">
                      {c.counselor ?? "No counselor"} · {c.assigned_to ?? "Nobody assigned"}
                    </p>

                    <p className="lock">
                      {c.days_in_stage} {c.days_in_stage === 1 ? "day" : "days"} here
                    </p>

                    {c.services.length > 0 && (
                      <p className="board-tags">
                        {c.services.map((s) => (
                          <span className="chip" key={s}>
                            {s}
                          </span>
                        ))}
                      </p>
                    )}

                    {c.chip && <p className={"chip" + chipTone(c.chip_urgency)}>{c.chip}</p>}

                    {/* The way a phone moves a card, where there is no dragging. */}
                    <label className="board-move">
                      <span className="lock">Move to…</span>
                      <select
                        value=""
                        onChange={(e) => {
                          const to = e.target.value;
                          e.currentTarget.value = "";
                          if (!to) return;
                          if (to === OFF_INACTIVE) setRemoving({ card: c, how: "inactive" });
                          else if (to === OFF_CLOSE) setRemoving({ card: c, how: "close" });
                          else setMoving({ card: c, to });
                        }}
                      >
                        <option value="">Choose a stage</option>
                        {STAGES.filter((s) => s !== c.stage).map((s) => (
                          <option key={s} value={s}>
                            {stageLabel(s)}
                          </option>
                        ))}
                        {/* Off the board, last, because it is not a stage. */}
                        <option value={OFF_INACTIVE}>Make inactive</option>
                        {canClose && <option value={OFF_CLOSE}>Close</option>}
                      </select>
                    </label>
                  </article>
                ))}
                {column.length === 0 && <p className="lock">Nobody here.</p>}
              </div>
            </section>
          );
        })}
      </div>

      {panel && (
        <SidePanel
          card={panel}
          canClose={canClose}
          onClose={() => setPanel(null)}
          onMove={(to) => {
            if (to === OFF_INACTIVE) setRemoving({ card: panel, how: "inactive" });
            else if (to === OFF_CLOSE) setRemoving({ card: panel, how: "close" });
            else setMoving({ card: panel, to });
            setPanel(null);
          }}
          onRemove={(how) => {
            setRemoving({ card: panel, how });
            setPanel(null);
          }}
        />
      )}

      {moving && (
        <MoveDialog
          card={moving.card}
          to={moving.to}
          categories={categories}
          onDone={() => setMoving(null)}
        />
      )}
      {removing?.how === "close" && (
        <CloseDialog card={removing.card} onDone={() => setRemoving(null)} />
      )}
      {removing?.how === "inactive" && (
        <DeactivateDialog card={removing.card} onDone={() => setRemoving(null)} />
      )}
    </>
  );
}

/** What a card says when it is opened rather than glanced at. */
function SidePanel({
  card,
  canClose,
  onClose,
  onMove,
  onRemove,
}: {
  card: Card;
  canClose: boolean;
  onClose: () => void;
  onMove: (to: string) => void;
  onRemove: (how: "inactive" | "close") => void;
}) {
  return (
    <aside className="board-panel">
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <h2 className="h2" style={{ margin: 0 }}>
          {card.name}
        </h2>
        <button type="button" className="btn ghost" onClick={onClose}>
          Close the panel
        </button>
      </div>

      <dl className="board-facts">
        <dt className="lock">Stage</dt>
        <dd>
          {stageLabel(card.stage)} · {card.days_in_stage} days
        </dd>
        <dt className="lock">Goal</dt>
        <dd>{card.goal ?? "Not recorded"}</dd>
        <dt className="lock">Assigned to</dt>
        <dd>{card.assigned_to ?? "Nobody"}</dd>
        <dt className="lock">Counselor</dt>
        <dd>{card.counselor ?? "None"}</dd>
        <dt className="lock">Latest note</dt>
        <dd>
          {card.last_note ? (
            <>
              {card.last_note}
              {card.last_note_on && <span className="lock"> — {card.last_note_on}</span>}
            </>
          ) : (
            "Nothing in the contact log yet"
          )}
        </dd>
      </dl>

      <label className="field" style={{ maxWidth: 260 }}>
        Move to
        <select
          value=""
          onChange={(e) => {
            const to = e.target.value;
            if (to) onMove(to);
          }}
        >
          <option value="">Choose a stage</option>
          {STAGES.filter((s) => s !== card.stage).map((s) => (
            <option key={s} value={s}>
              {stageLabel(s)}
            </option>
          ))}
          <option value={OFF_INACTIVE}>Make inactive</option>
          {canClose && <option value={OFF_CLOSE}>Close</option>}
        </select>
      </label>

      <h3 className="board-off-title">Remove from board</h3>
      <p className="lock">Two different things. Inactive keeps everything.</p>
      <div className="row2" style={{ gap: 8 }}>
        <button type="button" className="btn ghost" onClick={() => onRemove("inactive")}>
          Make inactive
        </button>
        {canClose && (
          <button type="button" className="btn ghost" onClick={() => onRemove("close")}>
            Close
          </button>
        )}
      </div>

      <div className="row2" style={{ gap: 8, marginTop: 14 }}>
        <Link className="btn ghost" href={`/clients/${card.client_id}`}>
          Open the record
        </Link>
        {/* Writing to the counselor is the commonest next thing after moving
            a card, so it is here rather than two screens away (owner, 23 Oct
            2026). It files on the client like any message from the record. */}
        <Link className="btn ghost" href={`/mail/compose?client=${card.client_id}`}>
          Write
        </Link>
      </div>
    </aside>
  );
}

/** Every move asks why, and Job Placement asks two things more. */
function MoveDialog({
  card,
  to,
  categories,
  onDone,
}: {
  card: Card;
  to: string;
  categories: FileCategory[];
  onDone: () => void;
}) {
  const [state, action, pending] = useActionState(moveClient, initial);
  const [busy, start] = useTransition();
  const [uploading, setUploading] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  /**
   * The file goes up before the move does.
   *
   * Straight from the browser to storage, the way Add file does it and for
   * the same reason: a fifty-megabyte scan has no business passing through a
   * server action. Only the row is recorded through the server, and only once
   * the bytes are safely up - and then the move carries that row's id, so the
   * stage history says which document came with it.
   *
   * If the upload fails the move does not happen. A move that quietly lost
   * its paperwork would be worse than one that did not happen.
   */
  async function submit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setProblem(null);
    const form = new FormData(e.currentTarget);
    const file = form.get("file") as File | null;
    form.delete("file");

    if (file && file.size > 0) {
      if (file.size > FIFTY_MB) {
        setProblem(`${file.name} is over 50 MB. Scan it at a lower resolution, or split it.`);
        return;
      }
      setUploading(true);
      try {
        const supabase = createClient();
        const ext = file.name.includes(".") ? file.name.split(".").pop() : "";
        const path = `clients/${card.client_id}/${crypto.randomUUID()}${ext ? `.${ext}` : ""}`;
        const { error } = await supabase.storage
          .from("client-files")
          .upload(path, file, { contentType: file.type || "application/octet-stream" });
        if (error) {
          setProblem(`That file did not go up: ${error.message}. Nobody was moved.`);
          setUploading(false);
          return;
        }

        const meta = new FormData();
        meta.set("client_id", card.client_id);
        meta.set("storage_path", path);
        meta.set("filename", file.name);
        meta.set("mime_type", file.type);
        meta.set("size_bytes", String(file.size));
        meta.set("category", String(form.get("category") ?? "Other"));
        meta.set("document_date", today());
        meta.set("note", `Attached when ${card.name} moved to ${stageLabel(to)}.`);
        meta.set("sha256", await fingerprint(file));

        const empty: FileState = { error: null, ok: null };
        const recorded = await recordAttachment(empty, meta);
        if (recorded.error) {
          setProblem(`${recorded.error} Nobody was moved.`);
          setUploading(false);
          return;
        }
        if (recorded.id) form.set("document_id", recorded.id);
      } catch (err) {
        setProblem(err instanceof Error ? err.message : "That file did not go up. Nobody was moved.");
        setUploading(false);
        return;
      }
      setUploading(false);
    }

    start(() => action(form));
  }

  if (state.ok) {
    return (
      <div className="board-dialog">
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Moved</h3>
          <p className="sub">{state.ok}</p>
          <button type="button" className="btn gold" onClick={onDone}>
            Back to the board
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="board-dialog">
      <form className="card" onSubmit={submit}>
        <h3 style={{ marginTop: 0 }}>
          {card.name} to {stageLabel(to)}
        </h3>
        <p className="sub">From {stageLabel(card.stage)}.</p>
        {(problem || state.error) && <div className="alert bad">{problem ?? state.error}</div>}

        <input type="hidden" name="client_id" value={card.client_id} />
        <input type="hidden" name="stage" value={to} />
        <input type="hidden" name="name" value={card.name} />

        <label className="field" htmlFor="move-note">
          Why
          <textarea id="move-note" name="note" rows={3} required />
        </label>

        <details>
          <summary>Attach a file or a form</summary>
          <label className="field" htmlFor="move-file">
            File
            <input id="move-file" name="file" type="file" />
          </label>
          <label className="field" htmlFor="move-category">
            What it is
            <select id="move-category" name="category" defaultValue="Other">
              {categories.map((c) => (
                <option key={c.key} value={c.key}>
                  {c.label}
                </option>
              ))}
            </select>
          </label>
          <p className="lock">It goes on the record and is kept with the move.</p>
        </details>

        {to === "Job Placement" && (
          <>
            <label className="field" htmlFor="move-employer">
              Employer
              <input id="move-employer" name="employer" required />
            </label>
            <label className="field" htmlFor="move-hired">
              Hire date
              <input id="move-hired" name="hire_date" type="date" required />
            </label>
            <p className="lock">This starts the placement clock.</p>
          </>
        )}

        <div className="row2" style={{ gap: 8 }}>
          <button className="btn gold" type="submit" disabled={pending || busy || uploading}>
            {uploading ? "Sending the file…" : pending || busy ? "Moving…" : "Move"}
          </button>
          <button
            className="btn ghost"
            type="button"
            onClick={onDone}
            disabled={pending || busy || uploading}
          >
            Leave them where they are
          </button>
        </div>
      </form>
    </div>
  );
}

/**
 * Making somebody inactive: a note, and nothing else changes.
 *
 * The words matter more than the form does. Somebody reaching for this has
 * usually decided the card is in the way, not that the work has ended, and
 * the two are one click apart - so this says what it leaves alone and where
 * to find them afterwards.
 */
function DeactivateDialog({ card, onDone }: { card: Card; onDone: () => void }) {
  const [state, action, pending] = useActionState(deactivateClient, initial);

  if (state.ok) {
    return (
      <div className="board-dialog">
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Off the board</h3>
          <p className="sub">{state.ok}</p>
          <p className="lock">Find them under All clients, and put them back from there.</p>
          <button type="button" className="btn gold" onClick={onDone}>
            Back to the board
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="board-dialog">
      <form className="card" action={action}>
        <h3 style={{ marginTop: 0 }}>Make {card.name} inactive</h3>
        <p className="sub">Their card leaves the board. Everything else stays.</p>
        {state.error && <div className="alert bad">{state.error}</div>}

        <input type="hidden" name="client_id" value={card.client_id} />
        <input type="hidden" name="name" value={card.name} />

        <label className="field" htmlFor="off-why">
          Why
          <textarea id="off-why" name="reason" rows={3} required />
        </label>

        <div className="row2" style={{ gap: 8 }}>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Taking off…" : "Make inactive"}
          </button>
          <button className="btn ghost" type="button" onClick={onDone} disabled={pending}>
            Leave them on the board
          </button>
        </div>
      </form>
    </div>
  );
}

/** Closing asks why, and the database refuses while money is out. */
function CloseDialog({ card, onDone }: { card: Card; onDone: () => void }) {
  const [state, action, pending] = useActionState(closeClient, initial);

  if (state.ok) {
    return (
      <div className="board-dialog">
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Closed</h3>
          <p className="sub">{state.ok}</p>
          <button type="button" className="btn gold" onClick={onDone}>
            Back to the board
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="board-dialog">
      <form className="card" action={action}>
        <h3 style={{ marginTop: 0 }}>Close {card.name}</h3>
        <p className="sub">They come off the board, and their open authorizations close with them.</p>
        {state.error && <div className="alert bad">{state.error}</div>}

        <input type="hidden" name="client_id" value={card.client_id} />
        <input type="hidden" name="name" value={card.name} />

        <label className="field" htmlFor="close-reason">
          Why
          <textarea id="close-reason" name="reason" rows={3} required />
        </label>

        <div className="row2" style={{ gap: 8 }}>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Closing…" : "Close them"}
          </button>
          <button className="btn ghost" type="button" onClick={onDone} disabled={pending}>
            Leave them on the board
          </button>
        </div>
      </form>
    </div>
  );
}
