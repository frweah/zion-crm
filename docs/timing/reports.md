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

## Record

| Person | Question | Seconds (before) | Seconds (after) | What made you stop |
|---|---|---|---|---|
| | 1 | | | |
| | 2 | | | |
| | 1 | | | |
| | 2 | | | |
| | 1 | | | |
| | 2 | | | |

## What the taps were counted from

Read from the code and from production on 19 November 2026, at `180a37e`,
before anything changed: `app/(app)/clients/[id]/reports/page.tsx`,
`[month]/page.tsx`, `month-actions.ts`, `make-report.tsx`,
`app/(app)/my-day/page.tsx`, `to-file.tsx`, `to-file-actions.ts`,
`app/(app)/dashboard/needs/page.tsx`, `lib/report-drafts.ts`,
`lib/report-period.ts`, `lib/week-report.ts`, `lib/roles.ts`,
`app/api/cron/reports/route.ts`, and the row-level policies on
`client_reports`, `client_weekly_reports` and `to_file`.
