/**
 * When a template may fill the note box, and when it must not.
 *
 * The whole risk in 10.2 is one sentence: somebody types three paragraphs,
 * changes the activity type because they picked the wrong one, and their
 * work vanishes. That has to be impossible, and it has to be impossible
 * without asking — a confirmation dialog on every dropdown change is its own
 * kind of failure.
 *
 * So the box is only ever filled when there is nothing to lose: it is empty,
 * or it still holds exactly the skeleton that was last put there and nobody
 * has touched it. Anything else is somebody's writing.
 *
 * Kept out of the component and free of imports so it can be checked on its
 * own, which is the only way to be sure about a rule whose failure mode is
 * silent.
 */

export type Fill =
  | { action: "fill"; body: string; applied: string }
  | { action: "clear"; body: ""; applied: null }
  | { action: "keep"; offer: string };

/**
 * What should happen to the note box when the activity type changes.
 *
 * `current`  — what is in the box now.
 * `applied`  — the template last written into it, if any; null once the
 *              person has typed, because at that point what is in the box is
 *              theirs whatever it started as.
 * `incoming` — the new type's template, or "" when that type has none.
 */
export function onTypeChange(current: string, applied: string | null, incoming: string): Fill {
  const untouched = current.trim() === "" || (applied !== null && current === applied);

  if (!untouched) {
    // Their writing stays. The new skeleton is offered as a button instead,
    // so choosing it is a decision rather than a side effect.
    return { action: "keep", offer: incoming };
  }

  if (incoming === "") {
    // The new type has no template — "General", or one switched off. An empty
    // box is the honest result; leaving the previous type's headings behind
    // would put a coaching session's questions on a note that is not one.
    return { action: "clear", body: "", applied: null };
  }

  return { action: "fill", body: incoming, applied: incoming };
}

/**
 * Has the person actually written anything, or only been handed headings?
 *
 * Used to stop a note being saved that is nothing but the skeleton. That is
 * not a documentation standard being enforced — it is the difference between
 * a note and an empty box with a shape, and saving one would put a record on
 * a client's file that says nothing while looking like it says something.
 */
export function isOnlyTemplate(text: string, applied: string | null): boolean {
  if (applied === null) return false;
  return normalize(text) === normalize(applied);
}

/**
 * Compare on content, not on whitespace. Somebody who tabs down through the
 * headings and saves has still written nothing, and a trailing newline is not
 * an answer.
 */
function normalize(s: string): string {
  return s
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .trim();
}
