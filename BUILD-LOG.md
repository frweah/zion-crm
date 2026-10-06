# Build log

What each block of work shipped, what was left out and why, and anything that
needs the owner. Newest at the bottom, so the file reads in the order the work
happened.

Written as each block deploys, so that picking the work up later means reading
the last entry rather than reconstructing it.

---

## Design language, step 1 — the bell, the person, Home as tiles

Deployed `e4603ec`, 5 Oct 2026.

**Shipped**

- A notifications bell in the header on every screen: unread texts, website
  chats, staff chat, mail, tasks due today or overdue, and alerts raised for
  the person's role — four tables in one list, in time order. Fetched when it
  is opened rather than polled.
- The two actions it offers are the two the dashboard already had: mark a
  conversation read, put an alert aside until tomorrow.
- An avatar menu top right: initials, name, role, their paperwork, their
  hours, sign out. These were at the foot of the sidebar among the screens.
- Home opens as tiles — work session, waiting for a reply, tasks due, today's
  appointments, caseload, alerts — one number each and a tap to the thing.
  Two columns on a phone.

**Chosen against**

- No new read-state table for the bell. It reads what the practice already
  keeps, so the bell and the screens cannot drift apart.
- Mail is wrapped so a stale Outlook token cannot empty the bell.

**Needs the owner** — nothing.

---

## Design language, step 2 — hubs, hub pages, the phone bar

Deployed `4cdf2ff`, 5 Oct 2026.

**Shipped**

- Six sidebar entries: **Home · Work · Communication · Billing · HR · Admin**.
  Work holds clients, their tasks, the jobs and the counselors;
  Communication holds mail, texts, chat, the website chat and the calendar.
- Each hub opens on a page of feature cards (`/work`, `/communication`,
  `/hr`) built from the hub's own navigation entries, so a screen added to a
  hub appears on its card page without anybody remembering to add it.
- A bottom bar on a phone — Home · Work · Communication · HR · More — with
  the unread badge on Communication. Hidden above 760px, where the sidebar
  does the job.
- `/hr` was a redirect to `/hours`; it is a hub page now. `/my-work` points at
  the hub. Every other old path still redirects.
- `check-nav` asserts the new six, that each hub's page exists, and where each
  screen lives; `check-screens` now accepts a page whose header comes from a
  shared body one directory up.

**Chosen against**

- Time clock, Updates, Directory and the knowledge base are named in the
  brief's hub lists but are steps 3, 4 and 6. Adding navigation entries for
  screens that do not exist would fail `check-nav` and the deploy check, so
  each joins its hub as it is built.

**Needs the owner** — nothing.

---

## Design language, step 3 — the time clock and My day

Deployed `8e3dd0c`, 5 Oct 2026.

**Shipped**

- **Time clock** (`/time-clock`, HR hub): clocked-in-since, today's total and
  this period's total as three tiles, with the clock in / clock out control
  under them. What is asked at clock-out is unchanged — the hours from the
  clock, the category, what the time was spent on — because it was already
  right; the categories offered are the person's role's (0134).
- **My day** (`/my-day`, Home): today in one column. Appointments at their
  time; tasks due and clients with something due under them, because a task
  due today does not happen at nine o'clock and pretending it does invents a
  schedule nobody agreed to.
- Every hub card now carries one line saying what the screen is for.

**Chosen against**

- The time clock does not repeat the session list or the statements; those are
  on Hours, one click away, and a screen that shows everything is a screen
  nobody reads.

**Needs the owner** — nothing.

---

## Design language, step 4 — Updates, Directory, and the two-pane Inbox

Deployed `8e07116`, 5 Oct 2026.

**Shipped**

- **Updates** (`/updates`): Admin posts a heading, what it says, an optional
  link, and who it is for — a role or everybody. A post can require
  acknowledgement and stay pinned until the person reads it. Reading is a
  button, not a scroll position. Admin sees how many have read each post and
  **who has not**, by name, which is the reason the feature exists.
- **Directory** (`/directory`): colleagues and counselors, with initials, role
  or office, and one tap to message, call or email.
- **The Inbox opens two panes** on a desk: the thread, and the client's card
  beside it — stage, who works them, who bills them, their counselor, their
  number, and what is next. Where there is no client, the same space offers
  the three things to do with an unknown number. One column on a phone,
  thread first.
- `verify_updates.sql`: only an Admin posts; a role's update is invisible to
  another role; a person records their own reading and nobody else's; Admin
  sees who has read and a colleague sees only themselves.

**Chosen against**

- No photographs in the directory. The practice holds none, and a page of
  grey circles says less than initials do — the same initials the avatar menu
  draws, so a person looks the same wherever they appear.
- No reactions on updates yet (the brief marks them optional). Read or not
  read is the question being asked; a thumbs-up would blur it.
- Attachments on an update have their columns but no upload yet: the
  `_Bills`-style folder work in E3 brings the same file plumbing, and doing it
  once is better than twice.

**Found while building** — the mail privacy check refuses any column that
could hold a message body, and read `updates.body` as one. It is an
announcement written in the CRM rather than a copy of anybody's message, but
the column was renamed to `text` (what `notifications` already uses) rather
than given an exception: a privacy rule with a list of exceptions is one
somebody will add to without thinking.

**Needs the owner** — nothing.

---

## Design language, step 5 — tasks as checklists

Deployed `42af989`, 5 Oct 2026.

**Shipped**

- **Steps.** A task can have steps, and a step is a task: same rules, same
  inline editing, same history. The database refuses a step of a step and
  refuses to let a step repeat — the task it belongs to does that.
- **Notes.** A word about why something slipped or what to try next, which
  was going in the title. A note cannot be edited afterwards: one somebody can
  rewrite is not a record of what was said.
- **Repeating.** Week, month, quarter, 90 days, year. Finishing one opens the
  next, **dated from the one just finished**, so a report sent a fortnight
  late does not push every future month a fortnight late — and the new one
  carries the steps, unfinished.
- The list is a checklist: a finished row strikes, goes grey and drops to the
  bottom; steps sit under their task rather than loose among the others.
- `verify_task_checklists.sql` covers all of it, including that a one-off
  opens nothing and a repeat stops when told to.

**Chosen against**

- Repeating is a database trigger rather than a nightly job, because a task is
  finished from four different screens and all four should behave the same.
- Attachments on a task are not built. The file plumbing arrives with E3's
  `_Bills` folder, and doing it once is better than twice.

**Needs the owner** — nothing.

---

## The timing check, corrected

Deployed `b4da89b`, 5 Oct 2026.

Step 5's deploy failed the timing check and the screens were fine — the smoke
check passed and production stayed up, which is why the timing check runs as
a job of its own. What it caught was Communication taking over eight seconds
to go quiet on the **first** click after a deploy; measured again warm, same
walk, same place: 548 ms.

The first request to a screen after a deploy wakes a serverless function.
That is Vercel's cold start, nobody can act on it, and a check that fails on a
slow morning is one somebody turns off. Each screen is now clicked once to
warm it and timed on the second visit. Ceiling stays at 8 s, target at 2 s.

---

## Design language, step 6 — the knowledge base, and the practice's own forms

Deployed `<pending>`, 5 Oct 2026.

**Shipped**

- **Knowledge base** (the old SOPs screen): articles as cards on shelves, with
  a search that reads the articles and not only their titles. "Where do I…?"
  is the first shelf, because it is the question people arrive with — they
  want a screen, not a procedure.
- **Forms and checklists** (`/forms-and-checklists`, HR hub): the practice's
  own three — a client visit, a worksite check, an incident — filled in on a
  phone and saved against the client. One field per line, real keyboards for
  numbers and dates, the camera for a photograph, and the photograph shrunk in
  the browser by the same helper the paperwork uploads use.
- A filled form is append-only, like a note. `verify_practice_forms.sql`
  proves it cannot be rewritten, cannot be filed as somebody else, is offered
  by role, and that a used template cannot be deleted out from under its
  entries.
- A client's filled forms join their records-request bundle (0140), which the
  bundle check demanded the first time it ran.

**Chosen against**

- USOR's forms are untouched. They are somebody else's document with somebody
  else's rules, they live on Billing, and they work.
- The signature field records that the filer signed rather than drawing a
  second signature pad: the practice already holds each person's signature
  from Paperwork, and two places to keep one is one too many.

**Needs the owner** — nothing.
