# Timing — Billing board and client dashboard, before

Two named questions, timed before either screen changes and again after
(brief, Part 1 step 3 and Part 4). If the after times are worse, the screens
go back.

**How to time one.** Start on Home, signed in. Start the stopwatch on the
first tap; stop it when the answer is on screen and you could say it out loud
without scrolling further. One practice run first, then the timed run. Write
down anything that made you stop and look.

Use a test client: **ZZ Smoke Board**.

Taps are counted the way `docs/screen-inventory.md` counts them: one tap each
for a bottom-bar item, a card, a tab, a row, a button or a dropdown. Typing
does not count. The header search box is two taps to a record — tap the box,
tap the result — and the Clients board is three.

## The two questions

### 1. What does client X owe us?

**Done when** you can say the figure.

| | Today |
|---|---|
| Shortest path | Search box → the client → **Billing** tab |
| Taps | **3** (4 from the Clients board) |
| Where the answer is | The authorizations table, column **"Invoiced, not paid"** |
| What you still have to do | **Add it up yourself.** There is one row per authorization and no total anywhere on the client record. Two authorizations means two figures and a sum in your head; the practice's busiest clients have more. |
| What is not on that screen | Nothing says what is *about* to be owed — "Left to bill" is a separate column and also per row. |
| The other route | Billing → Authorizations, search the client. This **cannot** answer it: that list is the working list, its money column is "Amount" (what the row is worth), and `billing_worklist` leaves out everything Paid or Closed, so what has already been settled is not there to subtract. |

### 2. What happened with client X this week?

**Done when** you have read the week.

| | Today |
|---|---|
| Shortest path | Search box → the client (**Activity** is the landing tab) |
| Taps | **2** |
| Where the answer is | The activity stream, grouped by day |
| What you still have to do | **Scan past the rest of the month.** The windows offered are Last 30 days, Last 90 days, Last year and Everything — there is no week. The stream opens on 30 days and you read down to where the week ends. |
| Above it on the way | "Coming up" (tasks and calendar events) and the Mail section sit between the header and the stream, so the week starts below two cards. |
| What is missing from it | There is no "Call" kind. A phone call is a **note of type "Phone call"**, so calls read as notes. |

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

Read from the code on 17 Nov 2026, at `50650b2`, before anything changed:
`app/(app)/billing/page.tsx` (the Authorizations tab), `worklist.tsx`,
`worklist-table.tsx`, `client-authorizations.tsx`,
`app/(app)/clients/[id]/page.tsx` (the Activity tab), `activity-tab.tsx`, and
`lib/client-tabs.ts`.
