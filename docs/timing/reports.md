# Timing — Reports, before

Two named questions, timed before the client-month board and again after
(brief, Part 1 step 3 and Part 4). If the after times are worse, the screen
goes back.

**How to time one.** Start on Home, signed in. Start the stopwatch on the
first tap; stop it when the answer is on screen and you could say it out loud
without scrolling further. One practice run first, then the timed run. Write
down anything that made you stop and look.

Taps are counted the way `docs/screen-inventory.md` counts them: one tap each
for a bottom-bar item, a card, a tab, a row, a button or a dropdown. Typing
does not count. The header search box is two taps to a record.

Who you are signed in as changes the answer to both questions, so each is
timed for the three people who would ask it: the Reports manager, the Job
Search owner who writes most of them, and the administrator.

## The two questions

### 1. Which reports are overdue, and whose are they?

**Done when** you can say the number and name the writers.

| | Today |
|---|---|
| Shortest path, for your own | **My day** → the "Reports due" section |
| Taps | **1** |
| What it says | One line per report: the client, the period, the status and `due 2026-11-05`. There is no overdue flag and no count — you compare each date with today yourself |
| Whose it shows | **Only your own.** The query is `owner_id = me`, for weeks and months alike |
| As the administrator | **Nothing.** The owner owns none of them, so the section is empty for him — and he is the person most likely to ask |
| As the Reports manager | **3 of the 19.** The other 16 belong to the Job Search owner and are not on her screen |
| The practice-wide answer | **Not on any screen.** There is no Reports hub, no tile on Home and no list under Needs attention. The only route is to open each client in turn — record → Documents → Reports — which is 3 taps per client, 54 for the eighteen active ones, and the table there does not carry the writer, so the second half of the question cannot be answered that way at all |
| What does say it | The **Friday email**, once a week, per person: "Reports: 16 to finish, all of them past their date." It names no client and nobody else's figures |

**The state it is timing against** (19 November 2026): 19 reports on file, all
of them October monthly reports, all Draft, all due 5 November, all fourteen
days past. 16 belong to the Job Search owner and 3 to the Reports manager.
Nothing has ever reached Reviewed, Signed or Sent.

### 2. What has gone into client X's November report?

**Done when** you can say what the month holds.

| | Today |
|---|---|
| The honest answer first | **There is no November report.** The scheduler assembles a month on the 1st of the next, so November's row is made on 1 December. The Reports table on the client's record lists periods that exist, and the latest is October |
| Shortest path to the answer anyway | Header search → client → **Documents** → **Reports** → the template dropdown → type `2026-11-01` → **Assemble it** → the new row |
| Taps | **7**, plus typing a date |
| What has to be known first | That "Assemble it" accepts any period up to today, that a month has to start on the first, and that November is therefore allowed. Nothing on the screen says so: the box is pre-filled with **October** |
| Who may do it | Admin, or the person the client is assigned to. The Reports manager may not, unless the client is hers |
| If the month does exist (October) | Header search → client → Documents → Reports → the period link. **5 taps**, and the draft lists the lines by service with the weeks it was built from |
| Where the count is | Nowhere before you open it. The Reports table says "2 of 3 confirmed" about the weeks, and nothing about how many notes, contacts, texts or hours the month holds |

**What a November report would hold**, across the eighteen active clients, read
on 19 November: 86 notes, 205 contact-log entries, 92 texts, 1 recording, 0
appointments, 0 logged service hours, and 52 weekly rows for the weeks from 26
October. The busiest single client's November is 12 notes, 32 contacts, 6
texts and 3 weekly rows.

Two of those zeros are not quiet months:

- **`calendar_events` has never held a row.** `buildPeriodContent` reads it,
  so an appointment has never appeared in any report. Appointments reach a
  client's record only by being filed from **To file**, which reads each
  person's Outlook live and writes a contact-log entry.
- **Texts and recordings are not read by the drafter at all.** A text reaches
  a report only if something wrote a contact-log row for it, and a recording
  only once it is confirmed, which writes a note and a contact.

## The two questions, after

Read from the code and from production on 20 November 2026, at the commit
that added **Reports** to the sidebar (`/client-reports`). Counted the same
way as above, so the two columns are comparable.

### 1. Which reports are overdue, and whose are they?

| | Before | After |
|---|---|---|
| Shortest path | My day → "Reports due" | **Reports** |
| Taps to the number | 1 | **1** — the Overdue tile carries it |
| Taps to the list behind it | not possible | **2** — press the tile and the board filters to those rows |
| Whose it shows | only your own | **everybody's**, with a Writer column and a Writer filter |
| As the administrator | nothing: he owns none | the same screen as everybody else |
| The practice-wide answer | not on any screen; 54 taps through the records and the writer not among them | **the screen** |

### 2. What has gone into client X's November report?

| | Before | After |
|---|---|---|
| Does November exist | no row until 1 December | **a row from the 1st**, built from the caseload |
| Taps to what the month holds | 7, plus typing `2026-11-01` | **1** — the row's "What's collected" chips |
| What it says | nothing until the draft is assembled | notes · contacts and calls · hours · weeks · applications · placements, with a red chip for a source the month expected and has not got |
| Taps to the draft | 7 and a typed date | **2** — Assemble it, then the period |

**What the first look at November says**, across the 18 active clients: 28
rows — 18 monthly reports owed and 10 service reports offered — all Not
started, the monthly ones due 5 December. 11 of the 28 carry "no hours
logged" against an hourly service, 2 carry "no notes", and **all 28 carry a
red week chip, because no weekly report has ever been confirmed**: 94 of
them, every one still Draft. That is not the board being noisy. It is the
first time the practice has been told.

## Record

| Person | Question | Seconds (before) | Seconds (after) | What made you stop |
|---|---|---|---|---|
| | 1 | | | |
| | 2 | | | |
| | 1 | | | |
| | 2 | | | |
| | 1 | | | |
| | 2 | | | |

## What the appointments were missing (ruling 8)

`calendar_events` has never held a row, and the owner's reading was that
appointments have therefore never reached a report. Half of that is right.

The sync could only match an Outlook event to a client by a `[Client #<number>]`
tag typed into the subject. **Nobody types it.** The To file sweep had read 64
appointments off the same calendars since 8 September, every one of which
names a client; not one carried the tag, so `calendar_events` took nothing
from Outlook in the life of the system and the practice's diary was invisible
to the Calendar screen, My day, the phone and the client record.

But the appointments did reach the reports, by the other road: filing one from
To file writes a contact-log entry, and the drafter reads those. Of October's
21 appointments, **13 were filed and are in October's reports as contacts; 8
were not, across 5 clients — so 5 of the 19 October drafts are short of
something the system had already seen.** No report has ever carried an
*appointment* line, which is the part that was dead.

Both halves are fixed at 0377: the sync matches by the client's name where
there is no tag and writes only where exactly one Active client is named, and
the drafter leaves out an appointment somebody has already filed, so the same
hour cannot be in a month twice.

## What the taps were counted from

Read from the code and from production on 19 November 2026, at `180a37e`,
before anything changed: `app/(app)/clients/[id]/reports/page.tsx`,
`[month]/page.tsx`, `month-actions.ts`, `make-report.tsx`,
`app/(app)/my-day/page.tsx`, `to-file.tsx`, `to-file-actions.ts`,
`app/(app)/dashboard/needs/page.tsx`, `lib/report-drafts.ts`,
`lib/report-period.ts`, `lib/week-report.ts`, `lib/roles.ts`,
`app/api/cron/reports/route.ts`, and the row-level policies on
`client_reports`, `client_weekly_reports` and `to_file`.
