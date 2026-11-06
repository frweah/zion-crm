"use client";

import { useEffect, useRef, useState } from "react";
import { EMOJI } from "@/lib/emoji";

/**
 * The emoji button in a chat composer (owner, 6 Nov 2026).
 *
 * One component for all three places the same chat appears - the pane, the
 * compact window and the full page at /team - because a picker written beside
 * each composer is three lists to keep in step, and the pane and the window
 * are already one component for exactly that reason.
 *
 * It hands back the character and nothing else. Where it goes in the message
 * is the composer's business: the full page holds its body in state and the
 * pane's textarea is uncontrolled on purpose, so each one inserts it its own
 * way and this one does not need to know which.
 *
 * Closes on Escape and on a press outside, like the other small panels. It
 * does not close on a pick: somebody choosing two in a row should not have to
 * open it twice.
 */
export function EmojiPicker({ onPick }: { onPick: (char: string) => void }) {
  const [open, setOpen] = useState(false);
  const holder = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!open) return;
    function away(e: MouseEvent) {
      if (!holder.current?.contains(e.target as Node)) setOpen(false);
    }
    function key(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", key);
    };
  }, [open]);

  return (
    <span className="emoji-holder" ref={holder}>
      <button
        type="button"
        className="btn ghost emoji-open"
        aria-expanded={open}
        aria-label="Emoji"
        onClick={() => setOpen((v) => !v)}
      >
        {/* The one place a drawn face is the word: this button's job is to
            offer the faces, so a label reading "Emoji" beside it would be
            saying the same thing twice. The accessible name is the word. */}
        <span aria-hidden="true">🙂</span>
      </button>

      {open && (
        <div className="emoji-panel" role="dialog" aria-label="Emoji">
          {EMOJI.map((group) => (
            <div key={group.name} className="emoji-group">
              <h4 className="emoji-group-name">{group.name}</h4>
              <div className="emoji-row">
                {group.emoji.map((e) => (
                  <button
                    key={e.char}
                    type="button"
                    className="emoji-one"
                    // The name somebody would type for it, so the panel
                    // teaches the shortcodes rather than hiding them.
                    title={`:${e.codes[0]}:`}
                    aria-label={e.codes[0].replace(/_/g, " ")}
                    onClick={() => onPick(e.char)}
                  >
                    <span aria-hidden="true">{e.char}</span>
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>
      )}
    </span>
  );
}
