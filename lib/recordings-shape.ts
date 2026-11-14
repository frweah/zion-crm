/**
 * The shape a meeting note takes (the owner's, 29 October; given 14 November).
 *
 * Here rather than in `lib/recordings.ts` because that module is
 * `server-only` - it holds two Azure keys - and the form a person confirms on
 * is a client component. One list of contact types, read by the screen, the
 * prompt and the database alike; three places that disagreed about it would
 * be three ways to write a note nobody can find.
 *
 * The date is not part of the shape. The practice already knows the day the
 * recording is of, from the document date on the file, and a machine that
 * guessed a date would be guessing the one thing a note is looked up by.
 */

/** The types of contact. `confirm_recording` holds the same three. */
export const CONTACT_KINDS = ["Job site visit", "Planning meeting", "Phone"] as const;

export type Summary = {
  /** One of CONTACT_KINDS, or empty when the machine did not say. */
  kind: string;
  present: string;
  discussed: string;
  decisions: string;
  /** In words, with a day only when one was said. Never a date to chase on. */
  next: string;
  /** One thing to ask next time. */
  question: string;
};
