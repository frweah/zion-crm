# Timing — Clients hub, before

Two named questions, timed before the Clients hub changes and again after
(brief, Part 1 step 5 and Part 5). If the after times are worse, the screen
goes back.

**How to time one.** Start on Home, signed in. Start the stopwatch on the
first tap; stop it when the answer is on screen and you could say it out loud
without scrolling further. One practice run first, then the timed run. Write
down anything that made you stop and look.

Use a test client: **ZZ Smoke Board**.

Taps are counted the way `docs/screen-inventory.md` counts them: one tap each
for a bottom-bar item, a card, a tab, a row, a button or a dropdown. Typing
does not count. The header search box is two taps to a record.

## The two questions

### 1. Find client X and see where they are

**Done when** you can say their stage.

| | Today |
|---|---|
| Shortest path | Header search box → the client. The stage is in the record's standing line |
| Taps | **2** |
| The other route | Clients, which opens on the **board** — the column a card sits in *is* the stage |
| Taps that way | 1 to Clients, then **find the card by eye**: the board has **no search box** and no filter of its own. Seven columns, one card per active client, and the only way to a named person is to read them |
| On a phone | Worse: seven columns do not fit, so the board shows **one column at a time** with a picker. Finding somebody means knowing their stage first, which is the question being asked |

### 2. Which clients has nobody touched in two weeks?

**Done when** you have the list.

| | Today |
|---|---|
| Shortest path | Clients → **All clients** → open the filters → type 14 into "Not touched in N days" → Apply |
| Taps | **4** |
| Where the answer is | The filtered list, with **Last activity** as a sortable column |
| What is not there | **No tile and no count anywhere says it.** The caseload strip counts every client, the active ones, the new ones this month and the active ones by stage — none of those is "nobody has touched these". So the question can only be answered by somebody who already knows the filter exists |
| What the board says | Nothing. The board has no last-contact anywhere on a card; it carries the client, the stage, the goal, the counselor, who they are assigned to, days in stage, services, one alert chip, and the last note's text and date |

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

Read from the code on 17 Nov 2026, at `695602c`, before anything changed:
`app/(app)/clients/page.tsx`, `board.tsx`, `filter-bar.tsx`,
`lib/list-filters.ts`, `lib/caseload.ts`, `app/(app)/caseload-summary.tsx`,
and the `clients_board` function.
