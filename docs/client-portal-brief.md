# Client portal — brief

21 Oct 2026. Replaces the paused September work on the `portal` branch, which
stays as the reference for section 1 and is not merged: main has moved about
130 migrations past it, so it is ported, not rebased.

## What it is for

A client of Zion Voc Rehab signs in from a phone and can:

1. see a notice that something is waiting for them,
2. write to their staff member and read the answer,
3. see what staff have asked them for and upload it,
4. build a resume if they have none.

Staff do all of their side from the screens they already use: the inbox, the
client record, Paperwork. Nothing in the portal needs a new staff screen it can
borrow from an existing one.

## Decisions taken (owner, 21 Oct 2026)

- **Sign-in:** a one-time code by text or by email, the client's choice, set
  on their account and changeable by them in Settings.
- **A finished resume** is filed in the client's documents straight away, with
  a task for a staff member to review and approve it. It counts as received
  only once approved.
- **English only** for the pilot.
- **Pilot first:** three to five clients, chosen by the owner, before the
  caseload.

## Sections

### 1. Access and consent (port of September's section 1)

Accounts (client or guardian with a guardianship document), one-time codes,
30-minute idle sessions, sign out everywhere from the record, versioned terms
that cannot be edited once stored (v1 is the attorney-approved text in
`supabase/portal-terms/v1.json`), append-only consent with time and address.
Nothing beyond the consent screen works without consent on the current terms.

New since September: the code channel is the client's choice (`code_channel`
on the account: Text or Email, only offered where the account has that
contact), and the staff panel invites with a choice of channel.

### 2. Messages and notices

- A portal conversation is a `conversations` row of a new kind, `portal`,
  owned by the client's assigned staff member, read by Admin, shown in the
  inbox beside texts and web chats. One thread per client account.
- A notice ("You have a new message from Zion Voc Rehab. Sign in to read it:
  <link>") goes by the account's channel. **A notice never carries content**:
  no names of services, no dates, nothing a lock screen should not show.
- A text notice goes only to a number with text consent on record, through
  the existing consent gate and quiet hours; otherwise it goes by email.
- Notices are batched: one per conversation per hour at most.

### 3. Requests and uploads

- Staff ask from the client record: a named item (Resume, Photo ID, Social
  Security card, Authorization, Other with a label), an optional note, an
  optional due date.
- The portal shows open requests as a list. Uploading answers the request and
  files the document in the client's documents with the requested category,
  under the same size and type limits as staff uploads.
- An answered request raises a task for the assigned staff member to review.
  Staff mark it accepted or ask again with a reason the client sees.

### 4. Resume builder

- Steps, one question per screen, in this order: contact details (filled from
  the record, editable), most recent job first (employer, job title, city,
  start and end month or "still working here", what they did), earlier jobs,
  education and training, certifications and licenses, skills, a short
  summary last (with plain examples to choose from).
- No job history is a valid answer: the resume then leads with skills,
  training and volunteer work.
- Saves after every step; leaving and coming back resumes where they were.
- Finishing produces a PDF and a Word file, filed in the client's documents
  as category Resume, with a task "Review resume for <client>" for the
  assigned staff member. Approve marks it approved and answers any open
  Resume request; Send back returns it to the client with a note.
- Nothing the client did not type is added to the resume.

## Standards

- Accessible to WCAG 2.1 AA: keyboard, screen reader, 200% zoom, large
  targets, plain language. The September accessibility gate (axe in a real
  browser) is brought back as a check.
- Every rule enforced in the database, each with a rollback-wrapped
  `verify_*.sql`, per CLAUDE.md.
- The portal speaks to a member of the public, so courtesy stands (the same
  exemption the website chat has in `check-copy`).

## Gate before any real client signs in

Client health and disability information will sit with Supabase and Vercel.
Each needs a signed Business Associate Agreement first:

- **Supabase:** HIPAA is a paid add-on on the Team plan only (Team starts at
  $599 a month; the add-on price is quoted by Supabase). HIPAA projects need
  point-in-time recovery, SSL enforcement, network restrictions and
  connection logging on.
- **Vercel:** a self-serve BAA is a paid add-on for Pro teams, signed from
  the team billing dashboard.

Building and testing on a preview with test clients does not need these. The
pilot does.
