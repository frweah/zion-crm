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

Deployed `<pending>`, 5 Oct 2026.

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
