/**
 * How a contact happened, and what counts as one.
 *
 * Four lists, and they are not the same list, which is the thing to get
 * straight before changing any of them:
 *
 *   CONTACT_METHODS       what a person picks on a note: in person, phone,
 *                         video, text. The database holds the same four in
 *                         `notes_method_check`.
 *   CONTACT_NOTE_TYPES    the note types that have to say how. The database
 *                         holds the same four in `note_is_contact`.
 *   NEEDS_METHOD          the types a *form* asks about, which is the list
 *                         above without Phone call: that type is the method,
 *                         and `notes_say_how` fills it in rather than asking.
 *   REAL_CONTACT_METHODS  what a line in the contact log has to say to count
 *                         as a contact on a client's month. The database
 *                         holds the same list in `is_real_contact`.
 *
 * Here as well as in the database because a screen cannot ask a plpgsql
 * function what to put in a dropdown, and `check-threads.mjs` asserts that
 * each of the four matches its half in the database rather than trusting this
 * comment to stay true.
 */

/** How a contact happened (owner, 23 November 2026, Part 3). */
export const CONTACT_METHODS = ["In person", "Phone", "Video", "Text"] as const;

export type ContactMethod = (typeof CONTACT_METHODS)[number];

/**
 * The note types that are a record of talking to somebody.
 *
 * Four of the ten. The six left out are left out for a reason each, and the
 * reasons are in migration 0378 beside `note_is_contact`: three of them are a
 * thing done rather than a conversation, two are written automatically when a
 * job application moves and nobody knows how the employer got in touch, and
 * one is an email, which is not one of the four methods.
 */
export const CONTACT_NOTE_TYPES = [
  "Phone call",
  "Meeting",
  "Coaching session",
  "No-show / not responding",
] as const;

/** The types a form asks about. A phone call is a phone call. */
export const NEEDS_METHOD: string[] = CONTACT_NOTE_TYPES.filter((t) => t !== "Phone call");

/**
 * What counts as a contact on a client's month (ruling 5).
 *
 * The five the owner named, plus the two older spellings of two of them -
 * "Phone call" from the counselor contact log's own form, and "Email sent",
 * which is what every report emailed out of the CRM has been logged as since
 * September. Everything else in that column is an event the system wrote
 * about itself.
 */
export const REAL_CONTACT_METHODS = [
  "Call",
  "Text",
  "Email",
  "Appointment",
  "In person",
  "Phone call",
  "Email sent",
] as const;

export const isRealContact = (method: string | null | undefined): boolean =>
  (REAL_CONTACT_METHODS as readonly string[]).includes((method ?? "").trim());
